defmodule JidoMessaging.Ingest do
  @moduledoc """
  Inbound message processing pipeline.

  Handles incoming messages from channels:
  1. Resolves/creates room by external binding
  2. Resolves/creates participant by external ID
  3. Builds normalized Message struct
  4. Persists message via adapter
  5. Returns message with context for handler processing

  ## Usage

      case Ingest.ingest_incoming(MyApp.Messaging, TelegramChannel, "bot_123", incoming_data) do
        {:ok, message, context} ->
          # message is persisted, context contains room/participant info
        {:error, reason} ->
          # handle error
      end
  """

  require Logger

  alias JidoMessaging.{
    MediaPolicy,
    Message,
    Content.Text,
    MsgContext,
    RoomServer,
    RoomSupervisor,
    Security,
    SessionKey,
    SessionManager,
    Signal
  }

  @type incoming :: JidoMessaging.Channel.incoming_message()
  @type policy_stage :: :gating | :moderation
  @type policy_denial :: {:policy_denied, policy_stage(), atom(), String.t()}
  @type security_denial :: Security.security_denial()
  @type ingest_error :: policy_denial() | security_denial() | term()
  @type ingest_opts :: keyword()

  @type context :: %{
          room: JidoMessaging.Room.t(),
          participant: JidoMessaging.Participant.t(),
          channel: module(),
          instance_id: String.t(),
          external_room_id: term(),
          instance_module: module()
        }

  @default_policy_timeout_ms 50
  @default_timeout_fallback :deny

  @doc """
  Process an incoming message from a channel.

  Returns `{:ok, message, context}` on success where:
  - `message` is the persisted Message struct
  - `context` contains room, participant, and channel info for reply handling

  Returns `{:ok, :duplicate}` if the message has already been processed.
  """
  @spec ingest_incoming(module(), module(), String.t(), incoming()) ::
          {:ok, Message.t(), context()} | {:ok, :duplicate} | {:error, ingest_error()}
  def ingest_incoming(messaging_module, channel_module, instance_id, incoming) do
    ingest_incoming(messaging_module, channel_module, instance_id, incoming, [])
  end

  @doc """
  Process an incoming message from a channel with ingest policy options.

  ## Options

    * `:gaters` - List of modules implementing `JidoMessaging.Gating` behaviour
    * `:gating_opts` - Keyword options passed to each gater
    * `:gating_timeout_ms` - Timeout per gater check (default: `50`)
    * `:moderators` - List of modules implementing `JidoMessaging.Moderation` behaviour
    * `:moderation_opts` - Keyword options passed to each moderator
    * `:moderation_timeout_ms` - Timeout per moderator check (default: `50`)
    * `:policy_timeout_fallback` - Timeout fallback policy (`:deny` or `:allow_with_flag`)
    * `:policy_error_fallback` - Crash/error fallback policy (`:deny` or `:allow_with_flag`)
    * `:security` - Runtime overrides for `JidoMessaging.Security` config
  """
  @spec ingest_incoming(module(), module(), String.t(), incoming(), ingest_opts()) ::
          {:ok, Message.t(), context()} | {:ok, :duplicate} | {:error, ingest_error()}
  def ingest_incoming(messaging_module, channel_module, instance_id, incoming, opts)
      when is_list(opts) do
    channel_type = channel_module.channel_type()
    instance_id = to_string(instance_id)
    external_room_id = incoming.external_room_id

    dedupe_key = build_dedupe_key(channel_type, instance_id, incoming)

    case JidoMessaging.Deduper.check_and_mark(messaging_module, dedupe_key) do
      :duplicate ->
        Logger.debug("[JidoMessaging.Ingest] Duplicate message ignored: #{inspect(dedupe_key)}")
        {:ok, :duplicate}

      :new ->
        do_ingest(
          messaging_module,
          channel_module,
          channel_type,
          instance_id,
          external_room_id,
          incoming,
          opts
        )
    end
  end

  @doc """
  Process an incoming message without deduplication check.

  Use this when you've already verified the message is not a duplicate,
  or when deduplication is handled externally.
  """
  @spec ingest_incoming!(module(), module(), String.t(), incoming()) ::
          {:ok, Message.t(), context()} | {:error, ingest_error()}
  def ingest_incoming!(messaging_module, channel_module, instance_id, incoming) do
    ingest_incoming!(messaging_module, channel_module, instance_id, incoming, [])
  end

  @doc """
  Process an incoming message without deduplication check and with ingest policy options.
  """
  @spec ingest_incoming!(module(), module(), String.t(), incoming(), ingest_opts()) ::
          {:ok, Message.t(), context()} | {:error, ingest_error()}
  def ingest_incoming!(messaging_module, channel_module, instance_id, incoming, opts)
      when is_list(opts) do
    channel_type = channel_module.channel_type()
    instance_id = to_string(instance_id)
    external_room_id = incoming.external_room_id

    do_ingest(
      messaging_module,
      channel_module,
      channel_type,
      instance_id,
      external_room_id,
      incoming,
      opts
    )
  end

  defp do_ingest(
         messaging_module,
         channel_module,
         channel_type,
         instance_id,
         external_room_id,
         incoming,
         opts
       ) do
    raw_payload = incoming_raw_payload(incoming)

    with {:ok, verify_result} <-
           Security.verify_sender(messaging_module, channel_module, incoming, raw_payload, opts),
         {:ok, room} <- resolve_room(messaging_module, channel_type, instance_id, incoming),
         {:ok, participant} <- resolve_participant(messaging_module, channel_type, incoming),
         {:ok, message} <-
           build_message(messaging_module, room, participant, incoming, channel_type, instance_id, opts),
         message <- put_verify_metadata(message, verify_result),
         msg_context <- build_msg_context(channel_module, instance_id, incoming, room, participant),
         {:ok, policy_message} <- apply_policy_pipeline(message, msg_context, opts),
         {:ok, persisted_message} <- messaging_module.save_message_struct(policy_message) do
      context = %{
        room: room,
        participant: participant,
        channel: channel_module,
        instance_id: instance_id,
        external_room_id: external_room_id,
        instance_module: messaging_module
      }

      persist_session_route(messaging_module, msg_context, room, channel_type, instance_id, external_room_id)

      add_to_room_server(messaging_module, room, persisted_message, participant)

      Logger.debug("[JidoMessaging.Ingest] Message #{persisted_message.id} ingested in room #{room.id}")

      Signal.emit_received(persisted_message, context)

      {:ok, persisted_message, context}
    end
  end

  defp persist_session_route(
         messaging_module,
         %MsgContext{} = msg_context,
         room,
         channel_type,
         instance_id,
         external_room_id
       ) do
    route = %{
      channel_type: channel_type,
      instance_id: instance_id,
      room_id: room.id,
      thread_id: msg_context.thread_root_id || msg_context.external_thread_id,
      external_room_id: to_string(external_room_id)
    }

    case SessionManager.set(messaging_module, SessionKey.from_context(msg_context), route) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[JidoMessaging.Ingest] Session route update skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp build_dedupe_key(channel_type, instance_id, incoming) do
    external_message_id = incoming[:external_message_id]
    external_room_id = incoming.external_room_id

    {channel_type, instance_id, external_room_id, external_message_id}
  end

  # Private helpers

  defp resolve_room(messaging_module, channel_type, instance_id, incoming) do
    external_id = to_string(incoming.external_room_id)

    room_attrs = %{
      type: map_chat_type(incoming[:chat_type]),
      name: incoming[:chat_title]
    }

    messaging_module.get_or_create_room_by_external_binding(
      channel_type,
      instance_id,
      external_id,
      room_attrs
    )
  end

  defp resolve_participant(messaging_module, channel_type, incoming) do
    external_id = to_string(incoming.external_user_id)

    participant_attrs = %{
      type: :human,
      identity: %{
        username: incoming[:username],
        display_name: incoming[:display_name]
      }
    }

    messaging_module.get_or_create_participant_by_external_id(
      channel_type,
      external_id,
      participant_attrs
    )
  end

  defp build_message(messaging_module, room, participant, incoming, channel_type, instance_id, opts) do
    with {:ok, content, media_metadata} <- build_content(incoming, opts) do
      reply_to_id = resolve_reply_to_id(messaging_module, channel_type, instance_id, incoming)

      message_attrs = %{
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: content,
        reply_to_id: reply_to_id,
        external_id: incoming[:external_message_id],
        status: :sent,
        metadata: build_metadata(incoming, channel_type, instance_id, media_metadata)
      }

      {:ok, Message.new(message_attrs)}
    end
  end

  defp build_msg_context(channel_module, instance_id, incoming, room, participant) do
    base_ctx = MsgContext.from_incoming(channel_module, instance_id, incoming)
    %{base_ctx | room_id: room.id, participant_id: participant.id}
  end

  defp resolve_reply_to_id(messaging_module, channel_type, instance_id, incoming) do
    external_reply_to_id = incoming[:external_reply_to_id]

    if external_reply_to_id do
      case messaging_module.get_message_by_external_id(channel_type, instance_id, external_reply_to_id) do
        {:ok, msg} -> msg.id
        _ -> nil
      end
    else
      nil
    end
  end

  defp build_content(incoming, opts) do
    text_content =
      case incoming do
        %{text: text} when is_binary(text) and text != "" -> [%Text{text: text}]
        _ -> []
      end

    media_payload = Map.get(incoming, :media, [])
    media_opts = media_policy_opts(opts)

    case MediaPolicy.normalize_inbound(media_payload, media_opts) do
      {:ok, media_content, media_metadata} ->
        {:ok, text_content ++ media_content, media_metadata}

      {:error, {:media_policy_denied, reason}, media_metadata} ->
        Logger.warning("[JidoMessaging.Ingest] Media policy rejection: #{inspect(reason)}")
        {:error, {:media_policy_denied, reason, media_metadata}}

      {:error, reason, media_metadata} ->
        Logger.warning("[JidoMessaging.Ingest] Media normalization rejection: #{inspect(reason)}")
        {:error, {:media_policy_denied, reason, media_metadata}}
    end
  end

  defp incoming_raw_payload(incoming) do
    case Map.get(incoming, :raw) do
      raw_payload when is_map(raw_payload) -> raw_payload
      _ -> %{}
    end
  end

  defp put_verify_metadata(%Message{} = message, %{decision: decision, metadata: metadata}) do
    security_metadata =
      Map.get(message.metadata, :security, %{})
      |> Map.put(
        :verify,
        %{
          decision: decision,
          metadata: metadata
        }
      )

    %{message | metadata: Map.put(message.metadata, :security, security_metadata)}
  end

  defp build_metadata(incoming, channel_type, instance_id, media_metadata) do
    %{
      external_message_id: incoming[:external_message_id],
      timestamp: incoming[:timestamp],
      channel: channel_type,
      instance_id: instance_id,
      username: incoming[:username],
      display_name: incoming[:display_name]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
    |> maybe_put_media_metadata(media_metadata)
  end

  defp media_policy_opts(opts) do
    case Keyword.get(opts, :media_policy, []) do
      value when is_list(value) -> value
      value when is_map(value) -> Map.to_list(value)
      _ -> []
    end
  end

  defp maybe_put_media_metadata(metadata, media_metadata) do
    has_media = media_metadata[:count] > 0
    has_rejections = media_metadata[:rejected] != []

    if has_media or has_rejections do
      Map.put(metadata, :media, media_metadata)
    else
      metadata
    end
  end

  defp map_chat_type(:private), do: :direct
  defp map_chat_type(:group), do: :group
  defp map_chat_type(:supergroup), do: :group
  defp map_chat_type(:channel), do: :channel
  defp map_chat_type(_), do: :direct

  defp apply_policy_pipeline(message, %MsgContext{} = msg_context, opts) do
    initial_state = %{decisions: [], flags: [], modified: false}

    with {:ok, gating_state} <- run_gating(msg_context, opts, initial_state),
         {:ok, moderated_message, policy_state} <- run_moderation(message, opts, gating_state) do
      {:ok, put_policy_metadata(moderated_message, policy_state)}
    end
  end

  defp run_gating(msg_context, opts, state) do
    gaters = Keyword.get(opts, :gaters, [])
    gater_opts = Keyword.get(opts, :gating_opts, [])
    timeout_ms = timeout_ms(opts, :gating_timeout_ms)

    case Enum.reduce_while(gaters, {:ok, state}, fn gater, {:ok, current_state} ->
           case run_policy_module(:gating, gater, fn -> gater.check(msg_context, gater_opts) end, timeout_ms) do
             {:ok, :allow, elapsed_ms} ->
               decision = build_decision(:gating, gater, :allow, elapsed_ms)
               emit_policy_telemetry(decision)
               {:cont, {:ok, append_decision(current_state, decision)}}

             {:ok, {:deny, reason, description}, elapsed_ms} ->
               decision = build_decision(:gating, gater, :deny, elapsed_ms, reason, description)
               emit_policy_telemetry(decision)

               {:halt,
                {:deny, {:policy_denied, :gating, reason, description}, append_decision(current_state, decision)}}

             {:ok, other, elapsed_ms} ->
               handle_policy_error(
                 :gating,
                 gater,
                 {:invalid_return, other},
                 elapsed_ms,
                 opts,
                 current_state
               )

             {:timeout, elapsed_ms} ->
               handle_policy_timeout(:gating, gater, elapsed_ms, opts, current_state)

             {:error, reason, elapsed_ms} ->
               handle_policy_error(:gating, gater, reason, elapsed_ms, opts, current_state)
           end
         end) do
      {:ok, final_state} ->
        {:ok, final_state}

      {:deny, denial, _state} ->
        {:error, denial}
    end
  end

  defp run_moderation(message, opts, state) do
    moderators = Keyword.get(opts, :moderators, [])
    moderator_opts = Keyword.get(opts, :moderation_opts, [])
    timeout_ms = timeout_ms(opts, :moderation_timeout_ms)

    case Enum.reduce_while(moderators, {:ok, message, state}, fn moderator, {:ok, current_message, current_state} ->
           case run_policy_module(
                  :moderation,
                  moderator,
                  fn -> moderator.moderate(current_message, moderator_opts) end,
                  timeout_ms
                ) do
             {:ok, :allow, elapsed_ms} ->
               decision = build_decision(:moderation, moderator, :allow, elapsed_ms)
               emit_policy_telemetry(decision)
               {:cont, {:ok, current_message, append_decision(current_state, decision)}}

             {:ok, {:flag, reason, description}, elapsed_ms} ->
               decision = build_decision(:moderation, moderator, :flag, elapsed_ms, reason, description)
               emit_policy_telemetry(decision)
               flag = build_flag(:moderation, moderator, reason, description, :moderation)

               {:cont,
                {:ok, current_message,
                 current_state
                 |> append_decision(decision)
                 |> append_flag(flag)}}

             {:ok, {:modify, %Message{} = modified_message}, elapsed_ms} ->
               decision = build_decision(:moderation, moderator, :modify, elapsed_ms)
               emit_policy_telemetry(decision)
               merged_message = merge_modified_message(current_message, modified_message)

               {:cont,
                {:ok, merged_message,
                 current_state
                 |> append_decision(decision)
                 |> mark_modified()}}

             {:ok, {:reject, reason, description}, elapsed_ms} ->
               decision = build_decision(:moderation, moderator, :reject, elapsed_ms, reason, description)
               emit_policy_telemetry(decision)

               {:halt,
                {:deny, {:policy_denied, :moderation, reason, description}, current_state |> append_decision(decision)}}

             {:ok, other, elapsed_ms} ->
               handle_moderation_error(
                 :moderation,
                 moderator,
                 {:invalid_return, other},
                 elapsed_ms,
                 opts,
                 current_message,
                 current_state
               )

             {:timeout, elapsed_ms} ->
               handle_moderation_timeout(
                 :moderation,
                 moderator,
                 elapsed_ms,
                 opts,
                 current_message,
                 current_state
               )

             {:error, reason, elapsed_ms} ->
               handle_moderation_error(
                 :moderation,
                 moderator,
                 reason,
                 elapsed_ms,
                 opts,
                 current_message,
                 current_state
               )
           end
         end) do
      {:ok, final_message, final_state} ->
        {:ok, final_message, final_state}

      {:deny, denial, _state} ->
        {:error, denial}
    end
  end

  defp run_policy_module(_stage, _policy_module, fun, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        elapsed_ms = elapsed_ms(started_at)
        {:ok, result, elapsed_ms}

      {:exit, reason} ->
        elapsed_ms = elapsed_ms(started_at)
        {:error, reason, elapsed_ms}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        elapsed_ms = elapsed_ms(started_at)
        {:timeout, elapsed_ms}
    end
  end

  defp handle_policy_timeout(stage, policy_module, elapsed_ms, opts, state) do
    fallback = timeout_fallback(opts)

    decision =
      build_decision(
        stage,
        policy_module,
        :timeout,
        elapsed_ms,
        :policy_timeout,
        "Policy module timed out",
        fallback
      )

    emit_policy_telemetry(decision)
    next_state = append_decision(state, decision)

    case fallback do
      :allow_with_flag ->
        flag =
          build_flag(
            stage,
            policy_module,
            :policy_timeout,
            "Policy module timed out",
            :timeout_fallback
          )

        {:cont, {:ok, append_flag(next_state, flag)}}

      :deny ->
        {:halt, {:deny, {:policy_denied, stage, :policy_timeout, "Policy module timed out"}, next_state}}
    end
  end

  defp handle_moderation_timeout(stage, policy_module, elapsed_ms, opts, message, state) do
    case handle_policy_timeout(stage, policy_module, elapsed_ms, opts, state) do
      {:cont, {:ok, next_state}} -> {:cont, {:ok, message, next_state}}
      {:halt, {:deny, denial, next_state}} -> {:halt, {:deny, denial, next_state}}
    end
  end

  defp handle_policy_error(stage, policy_module, reason, elapsed_ms, opts, state) do
    fallback = error_fallback(opts)
    description = "Policy module failed: #{inspect(reason)}"

    decision =
      build_decision(
        stage,
        policy_module,
        :error,
        elapsed_ms,
        :policy_error,
        description,
        fallback
      )

    emit_policy_telemetry(decision)
    next_state = append_decision(state, decision)

    case fallback do
      :allow_with_flag ->
        flag = build_flag(stage, policy_module, :policy_error, description, :error_fallback)
        {:cont, {:ok, append_flag(next_state, flag)}}

      :deny ->
        {:halt, {:deny, {:policy_denied, stage, :policy_error, description}, next_state}}
    end
  end

  defp handle_moderation_error(stage, policy_module, reason, elapsed_ms, opts, message, state) do
    case handle_policy_error(stage, policy_module, reason, elapsed_ms, opts, state) do
      {:cont, {:ok, next_state}} -> {:cont, {:ok, message, next_state}}
      {:halt, {:deny, denial, next_state}} -> {:halt, {:deny, denial, next_state}}
    end
  end

  defp merge_modified_message(%Message{} = original, %Message{} = modified) do
    merged_metadata =
      Map.merge(original.metadata || %{}, modified.metadata || %{})

    %{
      modified
      | id: original.id,
        room_id: original.room_id,
        sender_id: original.sender_id,
        role: original.role,
        reply_to_id: original.reply_to_id,
        external_id: original.external_id,
        external_reply_to_id: original.external_reply_to_id,
        thread_root_id: original.thread_root_id,
        external_thread_id: original.external_thread_id,
        status: original.status,
        inserted_at: original.inserted_at,
        metadata: merged_metadata
    }
  end

  defp append_decision(state, decision) do
    %{state | decisions: [decision | state.decisions]}
  end

  defp append_flag(state, flag) do
    %{state | flags: [flag | state.flags]}
  end

  defp mark_modified(state) do
    %{state | modified: true}
  end

  defp put_policy_metadata(message, %{decisions: decisions, flags: flags, modified: modified}) do
    if decisions == [] and flags == [] and not modified do
      message
    else
      existing_policy = Map.get(message.metadata, :policy, %{})

      policy_metadata =
        Map.merge(
          existing_policy,
          %{
            decisions: Enum.reverse(decisions),
            flags: Enum.reverse(flags),
            modified: modified,
            flagged: flags != []
          },
          fn
            :decisions, left, right when is_list(left) -> left ++ right
            :flags, left, right when is_list(left) -> left ++ right
            _, _, right -> right
          end
        )

      %{message | metadata: Map.put(message.metadata, :policy, policy_metadata)}
    end
  end

  defp build_decision(stage, policy_module, outcome, elapsed_ms, reason \\ nil, description \\ nil, fallback \\ nil) do
    %{
      stage: stage,
      policy_module: policy_module,
      outcome: outcome,
      elapsed_ms: elapsed_ms,
      reason: reason,
      description: description,
      fallback: fallback
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_flag(stage, policy_module, reason, description, source) do
    %{
      stage: stage,
      policy_module: policy_module,
      reason: reason,
      description: description,
      source: source
    }
  end

  defp emit_policy_telemetry(decision) do
    measurements = %{elapsed_ms: Map.get(decision, :elapsed_ms, 0)}

    metadata =
      decision
      |> Map.take([:stage, :policy_module, :outcome, :reason, :fallback])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    :telemetry.execute([:jido_messaging, :ingest, :policy, :decision], measurements, metadata)
  end

  defp timeout_ms(opts, key) do
    case Keyword.get(opts, key, @default_policy_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_policy_timeout_ms
    end
  end

  defp timeout_fallback(opts) do
    normalize_fallback(Keyword.get(opts, :policy_timeout_fallback, @default_timeout_fallback))
  end

  defp error_fallback(opts) do
    default = timeout_fallback(opts)
    normalize_fallback(Keyword.get(opts, :policy_error_fallback, default))
  end

  defp normalize_fallback(:allow_with_flag), do: :allow_with_flag
  defp normalize_fallback(:deny), do: :deny
  defp normalize_fallback(_), do: @default_timeout_fallback

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp add_to_room_server(messaging_module, room, message, participant) do
    case RoomSupervisor.get_or_start_room(messaging_module, room) do
      {:ok, pid} ->
        RoomServer.add_message(pid, message)
        RoomServer.add_participant(pid, participant)

      {:error, reason} ->
        Logger.warning("[JidoMessaging.Ingest] Failed to start room server: #{inspect(reason)}")
    end
  end
end
