defmodule JidoMessaging.OutboundGateway.Partition do
  @moduledoc false
  use GenServer

  alias JidoMessaging.Channel
  alias JidoMessaging.OutboundGateway

  @default_call_timeout 15_000

  @type pressure_level :: :normal | :warn | :degraded | :shed

  @type state :: %{
          instance_module: module(),
          partition: non_neg_integer(),
          queue: :queue.queue(),
          queue_size: non_neg_integer(),
          queue_capacity: pos_integer(),
          processing: boolean(),
          pressure_level: pressure_level(),
          max_attempts: pos_integer(),
          base_backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          sent_messages: map(),
          sent_order: [String.t()],
          sent_cache_size: pos_integer()
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
    registry = registry_name(instance_module)

    case Registry.lookup(registry, {:outbound_gateway_partition, partition}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec dispatch(module(), non_neg_integer(), OutboundGateway.request(), timeout()) ::
          {:ok, OutboundGateway.success_response()}
          | {:error, OutboundGateway.error_response()}
          | {:error, :partition_unavailable}
  def dispatch(instance_module, partition, request, timeout \\ @default_call_timeout) do
    case whereis(instance_module, partition) do
      nil -> {:error, :partition_unavailable}
      pid -> GenServer.call(pid, {:dispatch, request}, timeout)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      instance_module: Keyword.fetch!(opts, :instance_module),
      partition: Keyword.fetch!(opts, :partition),
      queue: :queue.new(),
      queue_size: 0,
      queue_capacity: Keyword.fetch!(opts, :queue_capacity),
      processing: false,
      pressure_level: :normal,
      max_attempts: Keyword.fetch!(opts, :max_attempts),
      base_backoff_ms: Keyword.fetch!(opts, :base_backoff_ms),
      max_backoff_ms: Keyword.fetch!(opts, :max_backoff_ms),
      sent_messages: %{},
      sent_order: [],
      sent_cache_size: Keyword.fetch!(opts, :sent_cache_size)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, request}, from, state) do
    with :ok <- validate_request(request),
         false <- queue_full?(state) do
      job = %{request: request, from: from}
      new_queue = :queue.in(job, state.queue)
      new_size = state.queue_size + 1
      state = %{state | queue: new_queue, queue_size: new_size} |> maybe_emit_pressure_transition(new_size)

      emit_outbound_event(:enqueued, %{queue_depth: new_size}, state, request, %{})

      new_state =
        if state.processing do
          state
        else
          send(self(), :process_next)
          %{state | processing: true}
        end

      {:noreply, new_state}
    else
      {:error, reason} ->
        {:reply, {:error, invalid_request_error(request, reason, state)}, state}

      true ->
        saturated_state = maybe_emit_pressure_transition(state, state.queue_capacity)
        {:reply, {:error, queue_full_error(request, saturated_state)}, saturated_state}
    end
  end

  @impl true
  def handle_info(:process_next, state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        next_state = %{state | processing: false} |> maybe_emit_pressure_transition(0)
        {:noreply, next_state}

      {{:value, job}, remaining_queue} ->
        new_size = max(state.queue_size - 1, 0)
        state = %{state | queue: remaining_queue, queue_size: new_size} |> maybe_emit_pressure_transition(new_size)
        {reply, post_state} = process_job(job.request, state)
        GenServer.reply(job.from, reply)

        if post_state.queue_size > 0 do
          send(self(), :process_next)
          {:noreply, %{post_state | processing: true}}
        else
          {:noreply, %{post_state | processing: false}}
        end
    end
  end

  defp process_job(request, state) do
    idempotency_key = request[:idempotency_key]

    case maybe_cached_success(idempotency_key, state) do
      {:ok, cached_response} ->
        response = Map.put(cached_response, :idempotent, true)
        emit_outbound_event(:skipped_duplicate, %{attempts: 0}, state, request, %{message_id: response.message_id})
        {{:ok, response}, state}

      :miss ->
        {result, state_after} = do_attempt(request, state, 1)

        case {result, idempotency_key} do
          {{:ok, response}, key} when is_binary(key) and key != "" ->
            {{:ok, response}, cache_success(state_after, key, response)}

          _ ->
            {result, state_after}
        end
    end
  end

  defp do_attempt(request, state, attempt) do
    max_attempts = sanitize_attempts(request[:max_attempts], state.max_attempts)

    case perform_operation(request) do
      {:ok, provider_result} ->
        message_id = extract_message_id(provider_result)

        success = %{
          operation: request.operation,
          message_id: message_id,
          result: provider_result,
          partition: state.partition,
          attempts: attempt,
          routing_key: request.routing_key,
          pressure_level: state.pressure_level,
          idempotent: false
        }

        emit_outbound_event(:completed, %{attempts: attempt}, state, request, %{message_id: message_id})
        {{:ok, success}, state}

      {:error, reason} ->
        category = OutboundGateway.classify_error(reason)

        emit_classification_event(state, request, %{
          category: category,
          reason: reason,
          attempt: attempt,
          max_attempts: max_attempts
        })

        if category == :retryable and attempt < max_attempts do
          backoff_ms = calculate_backoff(request, state, attempt)

          emit_outbound_event(
            :retry_scheduled,
            %{attempt: attempt, next_in_ms: backoff_ms},
            state,
            request,
            %{reason: reason}
          )

          Process.sleep(backoff_ms)
          do_attempt(request, state, attempt + 1)
        else
          disposition = if category == :retryable, do: :terminal, else: :terminal

          error = %{
            type: :outbound_error,
            category: category,
            disposition: disposition,
            operation: request.operation,
            reason: reason,
            attempt: attempt,
            max_attempts: max_attempts,
            partition: state.partition,
            routing_key: request.routing_key,
            retryable: category == :retryable
          }

          emit_outbound_event(
            :failed,
            %{attempts: attempt},
            state,
            request,
            %{reason: reason, category: category, disposition: disposition}
          )

          {{:error, error}, state}
        end
    end
  end

  defp perform_operation(%{operation: :send} = request) do
    invoke_channel(fn ->
      request.channel.send_message(request.external_room_id, request.payload, request.opts)
    end)
  end

  defp perform_operation(%{operation: :edit} = request) do
    invoke_channel(fn ->
      Channel.edit_message(
        request.channel,
        request.external_room_id,
        request.external_message_id,
        request.payload,
        request.opts
      )
    end)
  end

  defp perform_operation(%{operation: operation}) do
    {:error, {:unsupported_operation, operation}}
  end

  defp invoke_channel(fun) when is_function(fun, 0) do
    try do
      case fun.() do
        {:ok, result} when is_map(result) ->
          {:ok, result}

        {:ok, result} ->
          {:ok, %{message_id: result}}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:invalid_return, other}}
      end
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp maybe_cached_success(key, state) when is_binary(key) and key != "" do
    case Map.fetch(state.sent_messages, key) do
      {:ok, value} -> {:ok, value}
      :error -> :miss
    end
  end

  defp maybe_cached_success(_, _state), do: :miss

  defp cache_success(state, key, response) do
    if length(state.sent_order) >= state.sent_cache_size do
      [oldest_key | remaining_order] = state.sent_order
      pruned = Map.delete(state.sent_messages, oldest_key)

      %{
        state
        | sent_messages: Map.put(pruned, key, response),
          sent_order: remaining_order ++ [key]
      }
    else
      %{
        state
        | sent_messages: Map.put(state.sent_messages, key, response),
          sent_order: state.sent_order ++ [key]
      }
    end
  end

  defp calculate_backoff(request, state, attempt) do
    base_backoff_ms = sanitize_attempts(request[:base_backoff_ms], state.base_backoff_ms)
    max_backoff_ms = sanitize_attempts(request[:max_backoff_ms], state.max_backoff_ms)

    exponential = round(base_backoff_ms * :math.pow(2, max(attempt - 1, 0)))
    min(exponential, max_backoff_ms)
  end

  defp queue_full?(state), do: state.queue_size >= state.queue_capacity

  defp maybe_emit_pressure_transition(state, queue_size) do
    ratio = queue_size / max(state.queue_capacity, 1)
    level = pressure_level_for_ratio(ratio)

    if level != state.pressure_level do
      :telemetry.execute(
        [:jido_messaging, :pressure, :transition],
        %{
          queue_depth: queue_size,
          queue_capacity: state.queue_capacity,
          occupancy_ratio: ratio
        },
        %{
          component: :outbound_gateway,
          instance_module: state.instance_module,
          partition: state.partition,
          pressure_level: level
        }
      )
    end

    %{state | pressure_level: level}
  end

  defp pressure_level_for_ratio(ratio) when ratio >= 0.95, do: :shed
  defp pressure_level_for_ratio(ratio) when ratio >= 0.85, do: :degraded
  defp pressure_level_for_ratio(ratio) when ratio >= 0.70, do: :warn
  defp pressure_level_for_ratio(_ratio), do: :normal

  defp validate_request(request) when is_map(request) do
    cond do
      request[:operation] not in [:send, :edit] ->
        {:error, {:invalid_request, :operation}}

      not is_atom(request[:channel]) ->
        {:error, {:invalid_request, :channel}}

      is_nil(request[:external_room_id]) ->
        {:error, {:invalid_request, :external_room_id}}

      not is_binary(request[:payload]) ->
        {:error, {:invalid_request, :payload}}

      request[:operation] == :edit and is_nil(request[:external_message_id]) ->
        {:error, :missing_external_message_id}

      true ->
        :ok
    end
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp invalid_request_error(request, reason, state) do
    %{
      type: :outbound_error,
      category: OutboundGateway.classify_error(reason),
      disposition: :terminal,
      operation: request[:operation] || :send,
      reason: reason,
      attempt: 1,
      max_attempts: state.max_attempts,
      partition: state.partition,
      routing_key: request[:routing_key] || "unknown:unknown",
      retryable: false
    }
  end

  defp queue_full_error(request, state) do
    ratio = state.queue_capacity / max(state.queue_capacity, 1)

    :telemetry.execute(
      [:jido_messaging, :outbound, :queue_full],
      %{queue_depth: state.queue_capacity, queue_capacity: state.queue_capacity, occupancy_ratio: ratio},
      %{
        component: :outbound_gateway,
        instance_module: state.instance_module,
        partition: state.partition,
        operation: request[:operation] || :send
      }
    )

    %{
      type: :outbound_error,
      category: :terminal,
      disposition: :terminal,
      operation: request[:operation] || :send,
      reason: :queue_full,
      attempt: 1,
      max_attempts: state.max_attempts,
      partition: state.partition,
      routing_key: request[:routing_key] || "unknown:unknown",
      retryable: false
    }
  end

  defp emit_classification_event(state, request, metadata) do
    :telemetry.execute(
      [:jido_messaging, :outbound, :classified_error],
      %{attempt: metadata.attempt},
      %{
        component: :outbound_gateway,
        instance_module: state.instance_module,
        partition: state.partition,
        operation: request.operation,
        routing_key: request.routing_key,
        category: metadata.category,
        reason: metadata.reason,
        max_attempts: metadata.max_attempts
      }
    )
  end

  defp emit_outbound_event(event, measurements, state, request, metadata) do
    :telemetry.execute(
      [:jido_messaging, :outbound, event],
      measurements,
      Map.merge(
        %{
          component: :outbound_gateway,
          instance_module: state.instance_module,
          partition: state.partition,
          operation: request.operation,
          routing_key: request.routing_key,
          pressure_level: state.pressure_level
        },
        metadata
      )
    )
  end

  defp extract_message_id(result) when is_map(result) do
    Map.get(result, :message_id) || Map.get(result, :id) || Map.get(result, "message_id") ||
      Map.get(result, "id")
  end

  defp extract_message_id(result), do: result

  defp sanitize_attempts(value, _default) when is_integer(value) and value > 0, do: value
  defp sanitize_attempts(_value, default), do: default

  defp via_tuple(instance_module, partition) do
    {:via, Registry, {registry_name(instance_module), {:outbound_gateway_partition, partition}}}
  end

  defp registry_name(instance_module) do
    Module.concat(instance_module, Registry.Instances)
  end
end
