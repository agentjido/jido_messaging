defmodule Jido.Messaging.DeadLetter.ReplayWorker do
  @moduledoc false
  use GenServer

  alias Jido.Messaging.DeadLetter
  alias Jido.Messaging.OutboundGateway

  @default_replay_timeout 30_000

  @type state :: %{
          instance_module: module(),
          partition: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    partition = Keyword.fetch!(opts, :partition)
    name = via_tuple(instance_module, partition)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec whereis(module(), non_neg_integer()) :: pid() | nil
  def whereis(instance_module, partition) do
    registry = DeadLetter.replay_registry_name(instance_module)

    case Registry.lookup(registry, {:dead_letter_replay_worker, partition}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Replay a dead-letter id using the worker partition chosen by hash.
  """
  @spec replay(module(), String.t(), keyword()) ::
          {:ok, DeadLetter.replay_response()} | {:error, term()}
  def replay(instance_module, dead_letter_id, opts \\ [])
      when is_atom(instance_module) and is_binary(dead_letter_id) and is_list(opts) do
    partition = route_partition(instance_module, dead_letter_id)

    case whereis(instance_module, partition) do
      nil ->
        {:error, :replay_unavailable}

      pid ->
        timeout = Keyword.get(opts, :timeout, @default_replay_timeout)
        GenServer.call(pid, {:replay, dead_letter_id, opts}, timeout)
    end
  end

  @doc """
  Returns the replay worker partition for a dead-letter id.
  """
  @spec route_partition(module(), String.t()) :: non_neg_integer()
  def route_partition(instance_module, dead_letter_id) when is_atom(instance_module) and is_binary(dead_letter_id) do
    partitions = DeadLetter.config(instance_module)[:replay_partitions]
    :erlang.phash2(dead_letter_id, partitions)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       instance_module: Keyword.fetch!(opts, :instance_module),
       partition: Keyword.fetch!(opts, :partition)
     }}
  end

  @impl true
  def handle_call({:replay, dead_letter_id, opts}, _from, state) do
    force? = Keyword.get(opts, :force, false)

    with {:ok, replay_mode, record} <- DeadLetter.prepare_replay(state.instance_module, dead_letter_id, force?) do
      case replay_mode do
        :already_replayed ->
          {:reply, {:ok, %{status: :already_replayed, record: record}}, state}

        :replay ->
          replay_result = perform_replay(record, opts)

          case DeadLetter.complete_replay(state.instance_module, dead_letter_id, replay_result) do
            {:ok, updated_record} ->
              reply =
                case replay_result do
                  {:ok, response} ->
                    {:ok, %{status: :replayed, response: response, record: updated_record}}

                  {:error, reason} ->
                    {:error, reason}
                end

              {:reply, reply, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp perform_replay(record, opts) do
    request = record.request
    context = replay_context(request)
    replay_opts = replay_opts(record, request, opts)

    case request[:operation] do
      :send ->
        OutboundGateway.send_message(record.instance_module, context, request[:payload], replay_opts)

      :edit ->
        OutboundGateway.edit_message(
          record.instance_module,
          context,
          request[:external_message_id],
          request[:payload],
          replay_opts
        )

      :send_media ->
        OutboundGateway.send_media(record.instance_module, context, request[:payload], replay_opts)

      :edit_media ->
        OutboundGateway.edit_media(
          record.instance_module,
          context,
          request[:external_message_id],
          request[:payload],
          replay_opts
        )

      operation ->
        {:error, {:unsupported_replay_operation, operation}}
    end
  end

  defp replay_context(request) do
    %{
      channel: request[:channel],
      bridge_id: request[:bridge_id],
      external_room_id: request[:external_room_id]
    }
  end

  defp replay_opts(record, request, opts) do
    request_opts = to_keyword(request[:opts])
    override_opts = opts |> Keyword.get(:gateway_opts, []) |> to_keyword()

    idempotency_key =
      request[:idempotency_key] || request_opts[:idempotency_key] || "dead_letter:#{record.id}"

    request_opts
    |> Keyword.merge(override_opts)
    |> Keyword.put(:dead_letter_replay, true)
    |> Keyword.put(:idempotency_key, idempotency_key)
  end

  defp to_keyword(opts) when is_list(opts), do: opts
  defp to_keyword(opts) when is_map(opts), do: Map.to_list(opts)
  defp to_keyword(_opts), do: []

  defp via_tuple(instance_module, partition) do
    {:via, Registry, {DeadLetter.replay_registry_name(instance_module), {:dead_letter_replay_worker, partition}}}
  end
end
