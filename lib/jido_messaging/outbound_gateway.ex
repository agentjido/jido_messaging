defmodule Jido.Messaging.OutboundGateway do
  @moduledoc """
  Partitioned outbound gateway for send/edit delivery operations.

  The gateway enforces:

  - Stable partition routing by `bridge_id:external_room_id`
  - Bounded per-partition queues with pressure transition signals
  - Normalized outbound error categories for retry and terminal handling
  """

  alias Jido.Messaging.AdapterBridge
  alias Jido.Messaging.OutboundGateway.Partition
  alias Jido.Messaging.SessionManager

  @default_partition_count max(2, System.schedulers_online() * 2)
  @default_queue_capacity 128
  @default_max_attempts 3
  @default_base_backoff_ms 25
  @default_max_backoff_ms 500
  @default_sent_cache_size 1000
  @default_pressure_policy [
    warn_ratio: 0.70,
    degraded_ratio: 0.85,
    shed_ratio: 0.95,
    degraded_action: :throttle,
    degraded_throttle_ms: 5,
    shed_action: :drop_low,
    shed_drop_priorities: [:low]
  ]

  @type operation :: :send | :edit | :send_media | :edit_media
  @type priority :: :critical | :high | :normal | :low
  @type error_category :: :retryable | :terminal | :fatal

  @type request :: %{
          required(:operation) => operation(),
          required(:channel) => module(),
          required(:bridge_id) => String.t(),
          required(:external_room_id) => term(),
          required(:payload) => String.t() | map(),
          required(:opts) => keyword(),
          required(:routing_key) => String.t(),
          required(:session_key) => SessionManager.session_key(),
          optional(:external_message_id) => term(),
          optional(:route_resolution) => SessionManager.resolution(),
          optional(:idempotency_key) => String.t() | nil,
          optional(:max_attempts) => pos_integer() | nil,
          optional(:base_backoff_ms) => pos_integer() | nil,
          optional(:max_backoff_ms) => pos_integer() | nil,
          optional(:priority) => priority()
        }

  @type success_response :: %{
          required(:operation) => operation(),
          required(:message_id) => term(),
          required(:result) => map(),
          required(:partition) => non_neg_integer(),
          required(:attempts) => pos_integer(),
          required(:routing_key) => String.t(),
          required(:pressure_level) => :normal | :warn | :degraded | :shed,
          required(:idempotent) => boolean(),
          optional(:route_resolution) => SessionManager.resolution(),
          optional(:security) => map(),
          optional(:media) => map()
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
    dispatch(instance_module, build_request(instance_module, :send, context, text, nil, opts))
  end

  @doc """
  Edit a message through the outbound gateway.
  """
  @spec edit_message(module(), map(), term(), String.t(), keyword()) ::
          {:ok, success_response()} | {:error, error_response()}
  def edit_message(instance_module, context, external_message_id, text, opts \\ [])
      when is_atom(instance_module) and is_map(context) and is_binary(text) and is_list(opts) do
    dispatch(instance_module, build_request(instance_module, :edit, context, text, external_message_id, opts))
  end

  @doc """
  Send media through the outbound gateway.
  """
  @spec send_media(module(), map(), map(), keyword()) ::
          {:ok, success_response()} | {:error, error_response()}
  def send_media(instance_module, context, media_payload, opts \\ [])
      when is_atom(instance_module) and is_map(context) and is_map(media_payload) and is_list(opts) do
    dispatch(
      instance_module,
      build_request(instance_module, :send_media, context, media_payload, nil, opts)
    )
  end

  @doc """
  Edit media through the outbound gateway.
  """
  @spec edit_media(module(), map(), term(), map(), keyword()) ::
          {:ok, success_response()} | {:error, error_response()}
  def edit_media(instance_module, context, external_message_id, media_payload, opts \\ [])
      when is_atom(instance_module) and is_map(context) and is_map(media_payload) and is_list(opts) do
    dispatch(
      instance_module,
      build_request(
        instance_module,
        :edit_media,
        context,
        media_payload,
        external_message_id,
        opts
      )
    )
  end

  @doc """
  Resolve a stable partition for a routing key tuple.
  """
  @spec route_partition(module(), String.t(), term()) :: non_neg_integer()
  def route_partition(instance_module, bridge_id, external_room_id) when is_atom(instance_module) do
    count = partition_count(instance_module)
    :erlang.phash2(routing_key(bridge_id, external_room_id), count)
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
      sent_cache_size: @default_sent_cache_size,
      pressure_policy: @default_pressure_policy
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
  def classify_error(:load_shed), do: :terminal
  def classify_error({:load_shed, _}), do: :terminal
  def classify_error(:send_failed), do: :terminal
  def classify_error({:send_failed, _}), do: :terminal
  def classify_error(:missing_external_message_id), do: :terminal
  def classify_error({:missing_external_message_id, _}), do: :terminal
  def classify_error({:security_denied, :sanitize, {:security_failure, :retry}, _description}), do: :retryable
  def classify_error({:security_denied, :sanitize, _reason, _description}), do: :terminal
  def classify_error({:security_denied, :verify, _reason, _description}), do: :terminal
  def classify_error(:partition_unavailable), do: :fatal
  def classify_error({:partition_unavailable, _}), do: :fatal
  def classify_error(:invalid_request), do: :terminal
  def classify_error({:invalid_request, _}), do: :terminal
  def classify_error({:unsupported_operation, _}), do: :fatal
  def classify_error({:unsupported_media, _kind, _causes}), do: :terminal
  def classify_error({:media_policy_denied, _reason}), do: :terminal

  def classify_error(reason) do
    case AdapterBridge.classify_failure(reason) do
      :recoverable -> :retryable
      :degraded -> :terminal
      :fatal -> :fatal
    end
  end

  @doc """
  Returns a stable routing key used by partition hashing.
  """
  @spec routing_key(String.t(), term()) :: String.t()
  def routing_key(bridge_id, external_room_id) do
    "#{bridge_id}:#{external_room_id}"
  end

  defp dispatch(instance_module, request) do
    partition = route_partition(instance_module, request.bridge_id, request.external_room_id)

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

  defp build_request(instance_module, operation, context, payload, external_message_id, opts) do
    bridge_id = context_bridge_id(context)
    context_external_room_id = Map.get(context, :external_room_id)
    session_key = context_session_key(context, bridge_id, context_external_room_id)

    {external_room_id, route_resolution} =
      resolve_route_context(
        instance_module,
        session_key,
        context,
        bridge_id,
        context_external_room_id
      )

    %{
      operation: operation,
      channel: Map.get(context, :channel),
      bridge_id: bridge_id,
      external_room_id: external_room_id,
      payload: payload,
      opts: opts,
      external_message_id: external_message_id,
      routing_key: routing_key(bridge_id, external_room_id),
      session_key: session_key,
      route_resolution: route_resolution,
      idempotency_key: keyword_or_map_get(opts, :idempotency_key),
      max_attempts: keyword_or_map_get(opts, :max_attempts),
      base_backoff_ms: keyword_or_map_get(opts, :base_backoff_ms),
      max_backoff_ms: keyword_or_map_get(opts, :max_backoff_ms),
      priority: normalize_priority(keyword_or_map_get(opts, :priority))
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
    |> Keyword.update(:pressure_policy, @default_pressure_policy, &sanitize_pressure_policy/1)
  end

  defp context_bridge_id(context) do
    context
    |> Map.get(:bridge_id, "unknown")
    |> to_string()
  end

  defp resolve_route_context(instance_module, session_key, context, bridge_id, nil) do
    fallback_route = fallback_route(context, bridge_id, nil)
    {nil, fallback_resolution(instance_module, session_key, fallback_route, :miss, nil)}
  end

  defp resolve_route_context(instance_module, session_key, context, bridge_id, context_external_room_id) do
    fallback_route = fallback_route(context, bridge_id, context_external_room_id)

    case SessionManager.resolve(instance_module, session_key, [fallback_route]) do
      {:ok, resolution} ->
        {resolution.external_room_id, resolution}

      {:error, _reason} ->
        {context_external_room_id,
         fallback_resolution(
           instance_module,
           session_key,
           fallback_route,
           :session_unavailable,
           context_external_room_id
         )}
    end
  end

  defp fallback_resolution(instance_module, session_key, route, reason, external_room_id) do
    %{
      external_room_id: external_room_id,
      route: route,
      partition: SessionManager.route_partition(instance_module, session_key),
      session_key: session_key,
      source: :provided_fallback,
      fallback: true,
      stale: false,
      fallback_reason: reason
    }
  end

  defp fallback_route(context, bridge_id, external_room_id) do
    %{
      channel_type: context_channel_type(context),
      bridge_id: bridge_id,
      room_id: context_room_id(context),
      thread_id: context_thread_id(context),
      external_room_id: external_room_id
    }
  end

  defp context_session_key(context, bridge_id, external_room_id) do
    channel_type = context_channel_type(context)
    room_scope = context_room_id(context) || to_string(external_room_id || "unknown_room")

    {channel_type, bridge_id, room_scope, context_thread_id(context)}
  end

  defp context_channel_type(context) do
    cond do
      is_atom(context[:channel_type]) and not is_nil(context[:channel_type]) ->
        context[:channel_type]

      is_atom(context[:channel]) and function_exported?(context[:channel], :channel_type, 0) ->
        context[:channel].channel_type()

      true ->
        :unknown
    end
  end

  defp context_room_id(context) do
    cond do
      is_binary(context[:room_id]) ->
        context[:room_id]

      is_map(context[:room]) and is_binary(Map.get(context[:room], :id)) ->
        Map.get(context[:room], :id)

      true ->
        nil
    end
  end

  defp context_thread_id(context) do
    thread_id = context[:thread_root_id] || context[:external_thread_id] || context[:thread_id]
    if is_binary(thread_id), do: thread_id, else: nil
  end

  defp keyword_or_map_get(opts, key), do: Keyword.get(opts, key)

  defp sanitize_positive_integer(value, _default)
       when is_integer(value) and value > 0,
       do: value

  defp sanitize_positive_integer(_value, default), do: default

  defp sanitize_pressure_policy(value) do
    policy =
      cond do
        is_list(value) -> value
        is_map(value) -> Map.to_list(value)
        true -> @default_pressure_policy
      end

    warn_ratio = sanitize_ratio(policy[:warn_ratio], @default_pressure_policy[:warn_ratio])
    degraded_ratio = sanitize_ratio(policy[:degraded_ratio], @default_pressure_policy[:degraded_ratio])
    shed_ratio = sanitize_ratio(policy[:shed_ratio], @default_pressure_policy[:shed_ratio])

    {warn_ratio, degraded_ratio, shed_ratio} =
      if warn_ratio < degraded_ratio and degraded_ratio < shed_ratio do
        {warn_ratio, degraded_ratio, shed_ratio}
      else
        {@default_pressure_policy[:warn_ratio], @default_pressure_policy[:degraded_ratio],
         @default_pressure_policy[:shed_ratio]}
      end

    degraded_action =
      case policy[:degraded_action] do
        :throttle -> :throttle
        :none -> :none
        _ -> @default_pressure_policy[:degraded_action]
      end

    shed_action =
      case policy[:shed_action] do
        :drop_low -> :drop_low
        :none -> :none
        _ -> @default_pressure_policy[:shed_action]
      end

    shed_drop_priorities =
      case policy[:shed_drop_priorities] do
        priorities when is_list(priorities) ->
          priorities
          |> Enum.filter(&(&1 in [:critical, :high, :normal, :low]))
          |> Enum.uniq()
          |> case do
            [] -> @default_pressure_policy[:shed_drop_priorities]
            filtered -> filtered
          end

        _ ->
          @default_pressure_policy[:shed_drop_priorities]
      end

    [
      warn_ratio: warn_ratio,
      degraded_ratio: degraded_ratio,
      shed_ratio: shed_ratio,
      degraded_action: degraded_action,
      degraded_throttle_ms: sanitize_non_negative_integer(policy[:degraded_throttle_ms], 0),
      shed_action: shed_action,
      shed_drop_priorities: shed_drop_priorities
    ]
  end

  defp sanitize_ratio(value, _default) when is_float(value) and value > 0.0 and value < 1.0, do: value
  defp sanitize_ratio(_value, default), do: default

  defp sanitize_non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp sanitize_non_negative_integer(_value, default), do: default

  defp normalize_priority(value) when value in [:critical, :high, :normal, :low], do: value
  defp normalize_priority(_value), do: :normal
end
