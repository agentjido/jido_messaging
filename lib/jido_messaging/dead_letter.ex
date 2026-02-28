defmodule Jido.Messaging.DeadLetter do
  @moduledoc """
  Dead-letter storage and replay control plane for terminal outbound failures.

  Dead-letter records are written when outbound gateway work reaches terminal
  failure paths (including explicit load shedding). Replay execution is
  partitioned by dead-letter id via `Jido.Messaging.DeadLetter.ReplayWorker`.
  """
  use GenServer

  alias Jido.Messaging.OutboundGateway
  alias Jido.Messaging.DeadLetter.ReplayWorker

  @default_max_records 5_000
  @default_replay_partitions max(2, System.schedulers_online())

  @type record_status :: :active | :archived
  @type replay_status :: :never | :running | :succeeded | :failed

  @type replay_metadata :: %{
          status: replay_status(),
          attempts: non_neg_integer(),
          last_attempt_at: DateTime.t() | nil,
          last_outcome: :ok | :error | nil,
          last_result: term() | nil
        }

  @type record :: %{
          id: String.t(),
          instance_module: module(),
          status: record_status(),
          source: :outbound_gateway,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          category: OutboundGateway.error_category(),
          disposition: :retry | :terminal,
          reason: term(),
          retryable: boolean(),
          attempt: pos_integer() | nil,
          max_attempts: pos_integer() | nil,
          partition: non_neg_integer() | nil,
          routing_key: String.t() | nil,
          correlation_id: term(),
          idempotency_key: String.t() | nil,
          request: map(),
          diagnostics: map(),
          replay: replay_metadata()
        }

  @type replay_response ::
          %{status: :already_replayed, record: record()}
          | %{status: :replayed, response: OutboundGateway.success_response(), record: record()}

  @type state :: %{
          instance_module: module(),
          max_records: pos_integer(),
          records: %{optional(String.t()) => record()},
          order: [String.t()]
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    name = Keyword.get(opts, :name, server_name(instance_module))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns dead-letter configuration for a messaging instance.
  """
  @spec config(module()) :: keyword()
  def config(instance_module) when is_atom(instance_module) do
    defaults = [max_records: @default_max_records, replay_partitions: @default_replay_partitions]

    global_opts = Application.get_env(:jido_messaging, :dead_letter, [])
    module_opts = Application.get_env(instance_module, :dead_letter, [])

    defaults
    |> Keyword.merge(global_opts)
    |> Keyword.merge(module_opts)
    |> Keyword.update(:max_records, @default_max_records, &sanitize_positive_integer(&1, @default_max_records))
    |> Keyword.update(
      :replay_partitions,
      @default_replay_partitions,
      &sanitize_positive_integer(&1, @default_replay_partitions)
    )
  end

  @doc """
  Returns the registered dead-letter server name for an instance module.
  """
  @spec server_name(module()) :: atom()
  def server_name(instance_module), do: Module.concat(instance_module, DeadLetter)

  @doc """
  Returns the registered replay supervisor name for an instance module.
  """
  @spec replay_supervisor_name(module()) :: atom()
  def replay_supervisor_name(instance_module), do: Module.concat(instance_module, DeadLetterReplaySupervisor)

  @doc """
  Returns the registry used by replay workers for an instance module.
  """
  @spec replay_registry_name(module()) :: atom()
  def replay_registry_name(instance_module), do: Module.concat(instance_module, DeadLetterReplayRegistry)

  @doc """
  Capture a terminal outbound failure into dead-letter storage.
  """
  @spec capture_outbound_failure(module(), map(), map(), map()) :: {:ok, record()} | {:error, :unavailable}
  def capture_outbound_failure(instance_module, request, error, diagnostics \\ %{})
      when is_atom(instance_module) and is_map(request) and is_map(error) and is_map(diagnostics) do
    call(instance_module, {:capture_outbound_failure, request, error, diagnostics})
  end

  @doc """
  List dead-letter records.

  Options:
  - `:status` - `:active`, `:archived`, or `:all` (default: `:all`)
  - `:limit` - positive integer limit
  """
  @spec list(module(), keyword()) :: {:ok, [record()]} | {:error, :unavailable}
  def list(instance_module, opts \\ []) when is_atom(instance_module) and is_list(opts) do
    call(instance_module, {:list, opts})
  end

  @doc """
  Get a dead-letter record by id.
  """
  @spec get(module(), String.t()) :: {:ok, record()} | {:error, :not_found | :unavailable}
  def get(instance_module, dead_letter_id) when is_atom(instance_module) and is_binary(dead_letter_id) do
    call(instance_module, {:get, dead_letter_id})
  end

  @doc """
  Replay a dead-letter record through partitioned replay workers.
  """
  @spec replay(module(), String.t(), keyword()) ::
          {:ok, replay_response()} | {:error, term()}
  def replay(instance_module, dead_letter_id, opts \\ [])
      when is_atom(instance_module) and is_binary(dead_letter_id) and is_list(opts) do
    ReplayWorker.replay(instance_module, dead_letter_id, opts)
  end

  @doc """
  Archive a dead-letter record.
  """
  @spec archive(module(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def archive(instance_module, dead_letter_id) when is_atom(instance_module) and is_binary(dead_letter_id) do
    call(instance_module, {:archive, dead_letter_id})
  end

  @doc """
  Purge dead-letter records.

  Options:
  - `:status` - `:active`, `:archived`, or `:all` (default: `:archived`)
  - `:older_than_ms` - only purge records older than this age
  """
  @spec purge(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def purge(instance_module, opts \\ []) when is_atom(instance_module) and is_list(opts) do
    call(instance_module, {:purge, opts})
  end

  @doc false
  @spec prepare_replay(module(), String.t(), boolean()) ::
          {:ok, :replay | :already_replayed, record()} | {:error, :not_found | :archived | :replay_in_progress}
  def prepare_replay(instance_module, dead_letter_id, force? \\ false)
      when is_atom(instance_module) and is_binary(dead_letter_id) and is_boolean(force?) do
    call(instance_module, {:prepare_replay, dead_letter_id, force?})
  end

  @doc false
  @spec complete_replay(module(), String.t(), {:ok, term()} | {:error, term()}) ::
          {:ok, record()} | {:error, :not_found | :unavailable}
  def complete_replay(instance_module, dead_letter_id, replay_result)
      when is_atom(instance_module) and is_binary(dead_letter_id) do
    call(instance_module, {:complete_replay, dead_letter_id, replay_result})
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    config = config(instance_module)

    {:ok,
     %{
       instance_module: instance_module,
       max_records: config[:max_records],
       records: %{},
       order: []
     }}
  end

  @impl true
  def handle_call({:capture_outbound_failure, request, error, diagnostics}, _from, state) do
    record = build_record(state.instance_module, request, error, diagnostics)
    next_state = insert_record(state, record)

    :telemetry.execute(
      [:jido_messaging, :dead_letter, :captured],
      %{dead_letter_count: map_size(next_state.records)},
      %{
        instance_module: state.instance_module,
        dead_letter_id: record.id,
        category: record.category,
        operation: record.request[:operation],
        partition: record.partition
      }
    )

    {:reply, {:ok, record}, next_state}
  end

  def handle_call({:list, opts}, _from, state) do
    status_filter = opts |> Keyword.get(:status, :all) |> normalize_status_filter()
    limit = normalize_limit(Keyword.get(opts, :limit))

    records =
      state.order
      |> Enum.reverse()
      |> Enum.map(&Map.fetch!(state.records, &1))
      |> Enum.filter(&status_match?(&1.status, status_filter))
      |> maybe_limit(limit)

    {:reply, {:ok, records}, state}
  end

  def handle_call({:get, dead_letter_id}, _from, state) do
    case Map.fetch(state.records, dead_letter_id) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:archive, dead_letter_id}, _from, state) do
    case Map.fetch(state.records, dead_letter_id) do
      {:ok, record} ->
        now = DateTime.utc_now()
        updated = %{record | status: :archived, updated_at: now}
        {:reply, :ok, put_record(state, updated)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:purge, opts}, _from, state) do
    status_filter = opts |> Keyword.get(:status, :archived) |> normalize_status_filter()
    older_than_ms = normalize_older_than_ms(Keyword.get(opts, :older_than_ms))
    now_ms = System.system_time(:millisecond)

    removable_ids =
      state.order
      |> Enum.filter(fn dead_letter_id ->
        record = Map.fetch!(state.records, dead_letter_id)
        status_match?(record.status, status_filter) and older_than_match?(record, older_than_ms, now_ms)
      end)

    removable = MapSet.new(removable_ids)

    next_state = %{
      state
      | records: Map.drop(state.records, removable_ids),
        order: Enum.reject(state.order, &MapSet.member?(removable, &1))
    }

    {:reply, {:ok, length(removable_ids)}, next_state}
  end

  def handle_call({:prepare_replay, dead_letter_id, force?}, _from, state) do
    case Map.fetch(state.records, dead_letter_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        cond do
          record.status == :archived ->
            {:reply, {:error, :archived}, state}

          record.replay.status == :running and not force? ->
            {:reply, {:error, :replay_in_progress}, state}

          record.replay.status == :succeeded and not force? ->
            {:reply, {:ok, :already_replayed, record}, state}

          true ->
            now = DateTime.utc_now()

            updated =
              put_in(record.replay, %{
                status: :running,
                attempts: record.replay.attempts + 1,
                last_attempt_at: now,
                last_outcome: nil,
                last_result: nil
              })
              |> Map.put(:updated_at, now)

            :telemetry.execute(
              [:jido_messaging, :dead_letter, :replay_attempt],
              %{attempt: updated.replay.attempts},
              %{
                instance_module: state.instance_module,
                dead_letter_id: updated.id,
                partition: updated.partition,
                operation: updated.request[:operation]
              }
            )

            {:reply, {:ok, :replay, updated}, put_record(state, updated)}
        end
    end
  end

  def handle_call({:complete_replay, dead_letter_id, replay_result}, _from, state) do
    case Map.fetch(state.records, dead_letter_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        now = DateTime.utc_now()

        {replay_status, replay_outcome} =
          case replay_result do
            {:ok, _response} -> {:succeeded, :ok}
            {:error, _reason} -> {:failed, :error}
          end

        updated =
          put_in(record.replay, %{
            record.replay
            | status: replay_status,
              last_outcome: replay_outcome,
              last_result: replay_result
          })
          |> Map.put(:updated_at, now)

        :telemetry.execute(
          [:jido_messaging, :dead_letter, :replay_outcome],
          %{attempt: updated.replay.attempts},
          %{
            instance_module: state.instance_module,
            dead_letter_id: updated.id,
            partition: updated.partition,
            operation: updated.request[:operation],
            outcome: replay_outcome
          }
        )

        {:reply, {:ok, updated}, put_record(state, updated)}
    end
  end

  defp call(instance_module, message) do
    case Process.whereis(server_name(instance_module)) do
      nil -> {:error, :unavailable}
      pid -> GenServer.call(pid, message)
    end
  end

  defp build_record(instance_module, request, error, diagnostics) do
    now = DateTime.utc_now()

    %{
      id: "dlq_" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      status: :active,
      source: :outbound_gateway,
      inserted_at: now,
      updated_at: now,
      category: error[:category] || OutboundGateway.classify_error(error[:reason]),
      disposition: error[:disposition] || :terminal,
      reason: error[:reason],
      retryable: error[:retryable] == true,
      attempt: error[:attempt],
      max_attempts: error[:max_attempts],
      partition: error[:partition],
      routing_key: request[:routing_key],
      correlation_id: correlation_id(request),
      idempotency_key: request[:idempotency_key],
      request: request,
      diagnostics: diagnostics,
      replay: %{
        status: :never,
        attempts: 0,
        last_attempt_at: nil,
        last_outcome: nil,
        last_result: nil
      },
      instance_module: instance_module
    }
  end

  defp correlation_id(request) do
    opts = request[:opts]

    cond do
      is_list(opts) and Keyword.has_key?(opts, :correlation_id) ->
        Keyword.get(opts, :correlation_id)

      is_map(opts) and Map.has_key?(opts, :correlation_id) ->
        Map.get(opts, :correlation_id)

      is_map(opts) and Map.has_key?(opts, "correlation_id") ->
        Map.get(opts, "correlation_id")

      true ->
        request[:session_key]
    end
  end

  defp insert_record(state, record) do
    state
    |> put_record(record, append_order: true)
    |> maybe_trim_oldest()
  end

  defp put_record(state, record, opts \\ []) do
    append_order? = Keyword.get(opts, :append_order, false)
    records = Map.put(state.records, record.id, record)

    order =
      if append_order? and not Enum.member?(state.order, record.id) do
        state.order ++ [record.id]
      else
        state.order
      end

    %{state | records: records, order: order}
  end

  defp maybe_trim_oldest(state) do
    if length(state.order) <= state.max_records do
      state
    else
      [oldest_id | remaining_order] = state.order
      %{state | records: Map.delete(state.records, oldest_id), order: remaining_order}
    end
  end

  defp normalize_status_filter(:active), do: :active
  defp normalize_status_filter(:archived), do: :archived
  defp normalize_status_filter(_), do: :all

  defp status_match?(_status, :all), do: true
  defp status_match?(status, expected), do: status == expected

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value), do: nil

  defp maybe_limit(records, nil), do: records
  defp maybe_limit(records, limit), do: Enum.take(records, limit)

  defp normalize_older_than_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_older_than_ms(_value), do: nil

  defp older_than_match?(_record, nil, _now_ms), do: true

  defp older_than_match?(record, older_than_ms, now_ms) do
    inserted_ms = DateTime.to_unix(record.inserted_at, :millisecond)
    now_ms - inserted_ms >= older_than_ms
  end

  defp sanitize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp sanitize_positive_integer(_value, default), do: default
end
