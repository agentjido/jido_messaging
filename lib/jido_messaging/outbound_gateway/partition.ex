defmodule Jido.Messaging.OutboundGateway.Partition do
  @moduledoc false
  use GenServer

  require Logger

  @dialyzer {:nowarn_function, do_attempt: 3}
  @dialyzer {:nowarn_function, media_preflight: 1}
  @dialyzer {:nowarn_function, media_text_fallback: 3}

  alias Jido.Messaging.AdapterBridge
  alias Jido.Messaging.DeadLetter
  alias Jido.Messaging.MediaPolicy
  alias Jido.Messaging.OutboundGateway
  alias Jido.Messaging.Security

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
          pressure_policy: keyword(),
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
      pressure_policy: Keyword.fetch!(opts, :pressure_policy),
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
    case validate_request(request) do
      :ok ->
        if queue_full?(state) do
          saturated_state = maybe_emit_pressure_transition(state, state.queue_capacity)
          error = queue_full_error(request, saturated_state)

          {:reply, {:error, maybe_attach_dead_letter_id(saturated_state, request, error)}, saturated_state}
        else
          case maybe_apply_pressure_policy(state, request) do
            {:ok, next_state} ->
              job = %{request: request, from: from}
              new_queue = :queue.in(job, next_state.queue)
              new_size = next_state.queue_size + 1

              queued_state =
                %{next_state | queue: new_queue, queue_size: new_size} |> maybe_emit_pressure_transition(new_size)

              emit_outbound_event(:enqueued, %{queue_depth: new_size}, queued_state, request, %{})

              final_state =
                if queued_state.processing do
                  queued_state
                else
                  send(self(), :process_next)
                  %{queued_state | processing: true}
                end

              {:noreply, final_state}

            {:error, policy_error, policy_state} ->
              {:reply, {:error, maybe_attach_dead_letter_id(policy_state, request, policy_error)}, policy_state}
          end
        end

      {:error, reason} ->
        error = invalid_request_error(request, reason, state)
        {:reply, {:error, maybe_attach_dead_letter_id(state, request, error)}, state}
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
        state = %{state | queue: remaining_queue, queue_size: new_size} |> maybe_emit_pressure_transition(new_size + 1)
        {reply, post_state} = process_job(job.request, state)
        GenServer.reply(job.from, reply)

        if post_state.queue_size > 0 do
          send(self(), :process_next)
          {:noreply, %{post_state | processing: true} |> maybe_emit_pressure_transition(post_state.queue_size + 1)}
        else
          {:noreply, %{post_state | processing: false} |> maybe_emit_pressure_transition(0)}
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

    case perform_operation(state.instance_module, request) do
      {:ok, provider_result, security_result} ->
        message_id = extract_message_id(provider_result)
        success = build_success(state, request, attempt, message_id, provider_result, security_result, %{})

        emit_outbound_event(:completed, %{attempts: attempt}, state, request, %{message_id: message_id})
        {{:ok, success}, state}

      {:ok, provider_result, security_result, operation_metadata} ->
        message_id = extract_message_id(provider_result)

        success =
          build_success(
            state,
            request,
            attempt,
            message_id,
            provider_result,
            security_result,
            operation_metadata
          )

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

          {{:error, maybe_attach_dead_letter_id(state, request, error)}, state}
        end
    end
  end

  defp build_success(
         state,
         request,
         attempt,
         message_id,
         provider_result,
         security_result,
         operation_metadata
       ) do
    %{
      operation: request.operation,
      message_id: message_id,
      result: provider_result,
      partition: state.partition,
      attempts: attempt,
      routing_key: request.routing_key,
      pressure_level: state.pressure_level,
      route_resolution: request[:route_resolution],
      idempotent: false,
      security: %{sanitize: security_result}
    }
    |> maybe_put(:media, operation_metadata[:media])
  end

  defp perform_operation(instance_module, %{operation: :send} = request) do
    with {:ok, sanitized_payload, security_result} <-
           Security.sanitize_outbound(instance_module, request.channel, request.payload, request.opts),
         {:ok, provider_result} <-
           invoke_channel(fn ->
             AdapterBridge.send_message(
               request.channel,
               request.external_room_id,
               sanitized_payload,
               request.opts
             )
           end) do
      {:ok, provider_result, security_result}
    end
  end

  defp perform_operation(instance_module, %{operation: :edit} = request) do
    with {:ok, sanitized_payload, security_result} <-
           Security.sanitize_outbound(instance_module, request.channel, request.payload, request.opts),
         {:ok, provider_result} <-
           invoke_channel(fn ->
             AdapterBridge.edit_message(
               request.channel,
               request.external_room_id,
               request.external_message_id,
               sanitized_payload,
               request.opts
             )
           end) do
      {:ok, provider_result, security_result}
    end
  end

  defp perform_operation(instance_module, %{operation: :send_media} = request) do
    case media_preflight(request) do
      {:ok_media, payload, media_metadata} ->
        with {:ok, sanitized_payload, security_result} <-
               Security.sanitize_outbound(instance_module, request.channel, payload, request.opts),
             {:ok, provider_result} <-
               invoke_channel(fn ->
                 AdapterBridge.send_media(
                   request.channel,
                   request.external_room_id,
                   sanitized_payload,
                   request.opts
                 )
               end) do
          {:ok, provider_result, security_result, %{media: media_metadata}}
        end

      {:fallback_text, fallback_text, media_metadata} ->
        with {:ok, sanitized_payload, security_result} <-
               Security.sanitize_outbound(instance_module, request.channel, fallback_text, request.opts),
             {:ok, provider_result} <-
               invoke_channel(fn ->
                 AdapterBridge.send_message(
                   request.channel,
                   request.external_room_id,
                   sanitized_payload,
                   request.opts
                 )
               end) do
          {:ok, provider_result, security_result, %{media: media_metadata}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_operation(instance_module, %{operation: :edit_media} = request) do
    case media_preflight(request) do
      {:ok_media, payload, media_metadata} ->
        with {:ok, sanitized_payload, security_result} <-
               Security.sanitize_outbound(instance_module, request.channel, payload, request.opts),
             {:ok, provider_result} <-
               invoke_channel(fn ->
                 AdapterBridge.edit_media(
                   request.channel,
                   request.external_room_id,
                   request.external_message_id,
                   sanitized_payload,
                   request.opts
                 )
               end) do
          {:ok, provider_result, security_result, %{media: media_metadata}}
        end

      {:fallback_text, fallback_text, media_metadata} ->
        with {:ok, sanitized_payload, security_result} <-
               Security.sanitize_outbound(instance_module, request.channel, fallback_text, request.opts),
             {:ok, provider_result} <-
               invoke_channel(fn ->
                 AdapterBridge.edit_message(
                   request.channel,
                   request.external_room_id,
                   request.external_message_id,
                   sanitized_payload,
                   request.opts
                 )
               end) do
          {:ok, provider_result, security_result, %{media: media_metadata}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_operation(_instance_module, %{operation: operation}) do
    {:error, {:unsupported_operation, operation}}
  end

  defp media_preflight(request) do
    media_opts = media_policy_opts(request.opts)

    case MediaPolicy.prepare_outbound(request.payload, request.channel, request.operation, media_opts) do
      {:ok, payload, metadata} ->
        {:ok_media, payload, Map.put(metadata, :operation, request.operation)}

      {:fallback_text, fallback_text, metadata} ->
        Logger.warning(
          "[Jido.Messaging.OutboundGateway] Media fallback applied for #{inspect(request.channel)}: #{inspect(metadata.rejected)}"
        )

        case media_text_fallback(request, fallback_text, metadata) do
          {:ok, text_payload, fallback_metadata} ->
            {:fallback_text, text_payload, fallback_metadata}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason, metadata} ->
        Logger.warning(
          "[Jido.Messaging.OutboundGateway] Media dispatch rejected for #{inspect(request.channel)}: #{inspect(reason)} metadata=#{inspect(metadata)}"
        )

        {:error, reason}
    end
  end

  defp media_text_fallback(%{operation: :send_media}, fallback_text, metadata) do
    {:ok, fallback_text,
     Map.merge(metadata, %{
       fallback: true,
       fallback_mode: :text_send,
       fallback_operation: :send
     })}
  end

  defp media_text_fallback(%{operation: :edit_media, external_message_id: nil}, _fallback_text, _metadata) do
    {:error, :missing_external_message_id}
  end

  defp media_text_fallback(%{operation: :edit_media}, fallback_text, metadata) do
    {:ok, fallback_text,
     Map.merge(metadata, %{
       fallback: true,
       fallback_mode: :text_edit,
       fallback_operation: :edit
     })}
  end

  defp media_text_fallback(_request, _fallback_text, _metadata) do
    {:error, :unsupported_media_fallback}
  end

  defp media_policy_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :media_policy, []) do
      value when is_list(value) -> value
      value when is_map(value) -> Map.to_list(value)
      _ -> []
    end
  end

  defp media_policy_opts(_opts), do: []

  defp invoke_channel(fun) when is_function(fun, 0) do
    try do
      case fun.() do
        {:ok, result} when is_map(result) ->
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
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

  defp queue_full?(state), do: current_load(state) >= state.queue_capacity

  defp maybe_apply_pressure_policy(state, request) do
    projected_load = current_load(state) + min(mailbox_backlog(), 1) + 1
    ratio = projected_load / max(state.queue_capacity, 1)
    projected_state = maybe_emit_pressure_transition(state, projected_load)
    projected_level = projected_state.pressure_level
    priority = request[:priority] || :normal

    case pressure_action(projected_level, priority, projected_state.pressure_policy) do
      {:throttle, throttle_ms} ->
        emit_pressure_action(projected_state, request, projected_level, :throttle, throttle_ms, ratio)
        Process.sleep(throttle_ms)
        {:ok, projected_state}

      :shed_drop ->
        emit_pressure_action(projected_state, request, projected_level, :shed_drop, 0, ratio)
        {:error, load_shed_error(request, projected_state), projected_state}

      :allow ->
        {:ok, projected_state}
    end
  end

  defp maybe_emit_pressure_transition(state, queue_size) do
    ratio = queue_size / max(state.queue_capacity, 1)
    level = pressure_level_for_ratio(ratio, state.pressure_policy)

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

  defp pressure_level_for_ratio(ratio, policy) do
    cond do
      ratio >= policy[:shed_ratio] -> :shed
      ratio >= policy[:degraded_ratio] -> :degraded
      ratio >= policy[:warn_ratio] -> :warn
      true -> :normal
    end
  end

  defp pressure_action(:degraded, _priority, policy) do
    case policy[:degraded_action] do
      :throttle ->
        throttle_ms = max(policy[:degraded_throttle_ms] || 0, 0)
        if throttle_ms > 0, do: {:throttle, throttle_ms}, else: :allow

      _ ->
        :allow
    end
  end

  defp pressure_action(:shed, priority, policy) do
    case policy[:shed_action] do
      :drop_low ->
        if priority in (policy[:shed_drop_priorities] || []) do
          :shed_drop
        else
          :allow
        end

      _ ->
        :allow
    end
  end

  defp pressure_action(_level, _priority, _policy), do: :allow

  defp emit_pressure_action(state, request, pressure_level, action, throttle_ms, ratio) do
    :telemetry.execute(
      [:jido_messaging, :pressure, :action],
      %{
        queue_depth: state.queue_size,
        queue_capacity: state.queue_capacity,
        occupancy_ratio: ratio,
        throttle_ms: throttle_ms
      },
      %{
        component: :outbound_gateway,
        instance_module: state.instance_module,
        partition: state.partition,
        pressure_level: pressure_level,
        action: action,
        operation: request[:operation] || :send,
        priority: request[:priority] || :normal
      }
    )
  end

  defp validate_request(request) when is_map(request) do
    cond do
      request[:operation] not in [:send, :edit, :send_media, :edit_media] ->
        {:error, {:invalid_request, :operation}}

      not is_atom(request[:channel]) ->
        {:error, {:invalid_request, :channel}}

      is_nil(request[:external_room_id]) ->
        {:error, {:invalid_request, :external_room_id}}

      not valid_payload?(request[:operation], request[:payload]) ->
        {:error, {:invalid_request, :payload}}

      request[:priority] not in [:critical, :high, :normal, :low] ->
        {:error, {:invalid_request, :priority}}

      request[:operation] in [:edit, :edit_media] and is_nil(request[:external_message_id]) ->
        {:error, :missing_external_message_id}

      true ->
        :ok
    end
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp valid_payload?(operation, payload) when operation in [:send, :edit], do: is_binary(payload)
  defp valid_payload?(operation, payload) when operation in [:send_media, :edit_media], do: is_map(payload)
  defp valid_payload?(_operation, _payload), do: false

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

  defp load_shed_error(request, state) do
    %{
      type: :outbound_error,
      category: :terminal,
      disposition: :terminal,
      operation: request[:operation] || :send,
      reason: :load_shed,
      attempt: 1,
      max_attempts: state.max_attempts,
      partition: state.partition,
      routing_key: request[:routing_key] || "unknown:unknown",
      retryable: false
    }
  end

  defp maybe_attach_dead_letter_id(state, request, error) do
    if dead_letter_replay_request?(request) do
      error
    else
      diagnostics = %{
        pressure_level: state.pressure_level,
        queue_size: state.queue_size,
        queue_capacity: state.queue_capacity
      }

      case DeadLetter.capture_outbound_failure(state.instance_module, request, error, diagnostics) do
        {:ok, record} -> Map.put(error, :dead_letter_id, record.id)
        _ -> error
      end
    end
  end

  defp dead_letter_replay_request?(request) do
    case request[:opts] do
      opts when is_list(opts) ->
        Keyword.get(opts, :dead_letter_replay, false) == true

      opts when is_map(opts) ->
        Map.get(opts, :dead_letter_replay, false) == true or Map.get(opts, "dead_letter_replay", false) == true

      _ ->
        false
    end
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sanitize_attempts(value, _default) when is_integer(value) and value > 0, do: value
  defp sanitize_attempts(_value, default), do: default

  defp current_load(state) do
    state.queue_size + if(state.processing, do: 1, else: 0)
  end

  defp mailbox_backlog do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, value} when is_integer(value) and value > 0 -> value
      _ -> 0
    end
  end

  defp via_tuple(instance_module, partition) do
    {:via, Registry, {registry_name(instance_module), {:outbound_gateway_partition, partition}}}
  end

  defp registry_name(instance_module) do
    Module.concat(instance_module, Registry.Instances)
  end
end
