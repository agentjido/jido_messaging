defmodule JidoMessaging.OutboundGateway do
  @moduledoc """
  Partitioned outbound gateway for send/edit delivery operations.

  The gateway enforces:

  - Stable partition routing by `instance_id:external_room_id`
  - Bounded per-partition queues with pressure transition signals
  - Normalized outbound error categories for retry and terminal handling
  """

  alias JidoMessaging.Channel
  alias JidoMessaging.OutboundGateway.Partition

  @default_partition_count max(2, System.schedulers_online() * 2)
  @default_queue_capacity 128
  @default_max_attempts 3
  @default_base_backoff_ms 25
  @default_max_backoff_ms 500
  @default_sent_cache_size 1000

  @type operation :: :send | :edit
  @type error_category :: :retryable | :terminal | :fatal

  @type request :: %{
          required(:operation) => operation(),
          required(:channel) => module(),
          required(:instance_id) => String.t(),
          required(:external_room_id) => term(),
          required(:payload) => String.t(),
          required(:opts) => keyword(),
          required(:routing_key) => String.t(),
          optional(:external_message_id) => term(),
          optional(:idempotency_key) => String.t() | nil,
          optional(:max_attempts) => pos_integer() | nil,
          optional(:base_backoff_ms) => pos_integer() | nil,
          optional(:max_backoff_ms) => pos_integer() | nil
        }

  @type success_response :: %{
          required(:operation) => operation(),
          required(:message_id) => term(),
          required(:result) => map(),
          required(:partition) => non_neg_integer(),
          required(:attempts) => pos_integer(),
          required(:routing_key) => String.t(),
          required(:pressure_level) => :normal | :warn | :degraded | :shed,
          required(:idempotent) => boolean()
        }

  @type error_response :: %{
          required(:type) => :outbound_error,
          required(:category) => error_category(),
          required(:disposition) => :retry | :terminal,
          required(:operation) => operation(),
          required(:reason) => term(),
          required(:attempt) => pos_integer(),
          required(:max_attempts) => pos_integer(),
          required(:partition) => non_neg_integer(),
          required(:routing_key) => String.t(),
          required(:retryable) => boolean()
        }

  @doc """
  Send a message through the outbound gateway.
  """
  @spec send_message(module(), map(), String.t(), keyword()) ::
          {:ok, success_response()} | {:error, error_response()}
  def send_message(instance_module, context, text, opts \\ [])
      when is_atom(instance_module) and is_map(context) and is_binary(text) and is_list(opts) do
    dispatch(instance_module, build_request(:send, context, text, nil, opts))
  end

  @doc """
  Edit a message through the outbound gateway.
  """
  @spec edit_message(module(), map(), term(), String.t(), keyword()) ::
          {:ok, success_response()} | {:error, error_response()}
  def edit_message(instance_module, context, external_message_id, text, opts \\ [])
      when is_atom(instance_module) and is_map(context) and is_binary(text) and is_list(opts) do
    dispatch(instance_module, build_request(:edit, context, text, external_message_id, opts))
  end

  @doc """
  Resolve a stable partition for a routing key tuple.
  """
  @spec route_partition(module(), String.t(), term()) :: non_neg_integer()
  def route_partition(instance_module, instance_id, external_room_id) when is_atom(instance_module) do
    count = partition_count(instance_module)
    :erlang.phash2(routing_key(instance_id, external_room_id), count)
  end

  @doc """
  Returns configured partition count for the gateway.
  """
  @spec partition_count(module()) :: pos_integer()
  def partition_count(instance_module) do
    instance_module
    |> config()
    |> Keyword.fetch!(:partition_count)
  end

  @doc """
  Returns gateway config for an instance module.
  """
  @spec config(module()) :: keyword()
  def config(instance_module) when is_atom(instance_module) do
    defaults = [
      partition_count: @default_partition_count,
      queue_capacity: @default_queue_capacity,
      max_attempts: @default_max_attempts,
      base_backoff_ms: @default_base_backoff_ms,
      max_backoff_ms: @default_max_backoff_ms,
      sent_cache_size: @default_sent_cache_size
    ]

    global_opts = Application.get_env(:jido_messaging, :outbound_gateway, [])
    module_opts = Application.get_env(instance_module, :outbound_gateway, [])

    defaults
    |> Keyword.merge(global_opts)
    |> Keyword.merge(module_opts)
    |> sanitize_config()
  end

  @doc """
  Normalize raw provider/channel failures into gateway categories.
  """
  @spec classify_error(term()) :: error_category()
  def classify_error(:queue_full), do: :terminal
  def classify_error({:queue_full, _}), do: :terminal
  def classify_error(:send_failed), do: :terminal
  def classify_error({:send_failed, _}), do: :terminal
  def classify_error(:missing_external_message_id), do: :terminal
  def classify_error({:missing_external_message_id, _}), do: :terminal
  def classify_error(:partition_unavailable), do: :fatal
  def classify_error({:partition_unavailable, _}), do: :fatal
  def classify_error(:invalid_request), do: :terminal
  def classify_error({:invalid_request, _}), do: :terminal
  def classify_error({:unsupported_operation, _}), do: :fatal

  def classify_error(reason) do
    case Channel.classify_failure(reason) do
      :recoverable -> :retryable
      :degraded -> :terminal
      :fatal -> :fatal
    end
  end

  @doc """
  Returns a stable routing key used by partition hashing.
  """
  @spec routing_key(String.t(), term()) :: String.t()
  def routing_key(instance_id, external_room_id) do
    "#{instance_id}:#{external_room_id}"
  end

  defp dispatch(instance_module, request) do
    partition = route_partition(instance_module, request.instance_id, request.external_room_id)

    case Partition.dispatch(instance_module, partition, request) do
      {:error, :partition_unavailable} ->
        {:error,
         %{
           type: :outbound_error,
           category: :fatal,
           disposition: :terminal,
           operation: request.operation,
           reason: :partition_unavailable,
           attempt: 1,
           max_attempts: request.max_attempts || config(instance_module)[:max_attempts],
           partition: partition,
           routing_key: request.routing_key,
           retryable: false
         }}

      result ->
        result
    end
  end

  defp build_request(operation, context, text, external_message_id, opts) do
    instance_id = context_instance_id(context)
    external_room_id = Map.get(context, :external_room_id)

    %{
      operation: operation,
      channel: Map.get(context, :channel),
      instance_id: instance_id,
      external_room_id: external_room_id,
      payload: text,
      opts: opts,
      external_message_id: external_message_id,
      routing_key: routing_key(instance_id, external_room_id),
      idempotency_key: keyword_or_map_get(opts, :idempotency_key),
      max_attempts: keyword_or_map_get(opts, :max_attempts),
      base_backoff_ms: keyword_or_map_get(opts, :base_backoff_ms),
      max_backoff_ms: keyword_or_map_get(opts, :max_backoff_ms)
    }
  end

  defp sanitize_config(config) do
    config
    |> Keyword.update(:partition_count, @default_partition_count, fn value ->
      sanitize_positive_integer(value, @default_partition_count)
    end)
    |> Keyword.update(:queue_capacity, @default_queue_capacity, fn value ->
      sanitize_positive_integer(value, @default_queue_capacity)
    end)
    |> Keyword.update(:max_attempts, @default_max_attempts, fn value ->
      sanitize_positive_integer(value, @default_max_attempts)
    end)
    |> Keyword.update(:base_backoff_ms, @default_base_backoff_ms, fn value ->
      sanitize_positive_integer(value, @default_base_backoff_ms)
    end)
    |> Keyword.update(:max_backoff_ms, @default_max_backoff_ms, fn value ->
      sanitize_positive_integer(value, @default_max_backoff_ms)
    end)
    |> Keyword.update(:sent_cache_size, @default_sent_cache_size, fn value ->
      sanitize_positive_integer(value, @default_sent_cache_size)
    end)
  end

  defp context_instance_id(context) do
    context
    |> Map.get(:instance_id, "unknown")
    |> to_string()
  end

  defp keyword_or_map_get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp keyword_or_map_get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp keyword_or_map_get(_opts, _key), do: nil

  defp sanitize_positive_integer(value, _default)
       when is_integer(value) and value > 0,
       do: value

  defp sanitize_positive_integer(_value, default), do: default
end
