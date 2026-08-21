defmodule Jido.Messaging.Ingest do
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

  alias Jido.Chat.Content.Text

  alias Jido.Messaging.{
    Context,
    Message,
    MediaPolicy,
    MsgContext,
    MsgContext.Normalizer,
    MsgContext.CommandParser,
    RoomServer,
    RoomSupervisor,
    Security,
    SessionKey,
    SessionManager,
    Signal,
    Thread
  }

  @type incoming :: Jido.Chat.Incoming.t() | map()
  @type policy_stage :: :gating | :moderation
  @type policy_denial :: {:policy_denied, policy_stage(), atom(), String.t()}
  @type security_denial :: Security.security_denial()
  @type ingest_error :: policy_denial() | security_denial() | term()
  @type ingest_opts :: keyword()

  @type context :: Context.t()

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
  def ingest_incoming(messaging_module, channel_module, bridge_id, incoming) do
    ingest_incoming(messaging_module, channel_module, bridge_id, incoming, [])
  end

  @doc """
  Process an incoming message from a channel with ingest policy options.

  ## Options

    * `:gaters` - List of modules implementing `Jido.Messaging.Gating` behaviour
    * `:gating_opts` - Keyword options passed to each gater
    * `:gating_timeout_ms` - Timeout per gater check (default: `50`)
    * `:moderators` - List of modules implementing `Jido.Messaging.Moderation` behaviour
    * `:moderation_opts` - Keyword options passed to each moderator
    * `:moderation_timeout_ms` - Timeout per moderator check (default: `50`)
    * `:policy_timeout_fallback` - Timeout fallback policy (`:deny` or `:allow_with_flag`)
    * `:policy_error_fallback` - Crash/error fallback policy (`:deny` or `:allow_with_flag`)
    * `:security` - Runtime overrides for `Jido.Messaging.Security` config
    * `:require_mention` - Require `MsgContext.was_mentioned` to be true
    * `:allowed_prefixes` - Allowed command prefixes for parsed commands
    * `:mention_targets` - Mention targets used to normalize `was_mentioned`
    * `:command_prefixes` - Command parser prefix candidates
    * `:command_max_text_bytes` - Max message size for command parsing
    * `:mentions_max_text_bytes` - Max message size for mention adapter parsing
  """
  @spec ingest_incoming(module(), module(), String.t(), incoming(), ingest_opts()) ::
          {:ok, Message.t(), context()} | {:ok, :duplicate} | {:error, ingest_error()}
  def ingest_incoming(messaging_module, channel_module, bridge_id, incoming, opts)
      when is_list(opts) do
    channel_type = Jido.Messaging.AdapterBridge.channel_type(channel_module)
    bridge_id = to_string(bridge_id)
    external_room_id = incoming.external_room_id

    case build_dedupe_key(channel_type, bridge_id, incoming) do
      :skip ->
        do_ingest(
          messaging_module,
          channel_module,
          channel_type,
          bridge_id,
          external_room_id,
          incoming,
          opts
        )

      {:ok, dedupe_key} ->
        ingest_with_dedupe_claim(
          messaging_module,
          channel_module,
          channel_type,
          bridge_id,
          external_room_id,
          incoming,
          opts,
          dedupe_key
        )
    end
  end

  defp ingest_with_dedupe_claim(
         messaging_module,
         channel_module,
         channel_type,
         bridge_id,
         external_room_id,
         incoming,
         opts,
         dedupe_key
       ) do
    case Jido.Messaging.Deduper.claim(messaging_module, dedupe_key) do
      :duplicate ->
        Logger.debug("[Jido.Messaging.Ingest] Duplicate message ignored: #{inspect(dedupe_key)}")
        {:ok, :duplicate}

      {:ok, claim_token} ->
        result =
          do_ingest(
            messaging_module,
            channel_module,
            channel_type,
            bridge_id,
            external_room_id,
            incoming,
            opts
          )

        finalize_dedupe_claim(messaging_module, dedupe_key, claim_token, result)
    end
  end

  defp finalize_dedupe_claim(messaging_module, dedupe_key, claim_token, {:ok, _message, _context} = result) do
    case Jido.Messaging.Deduper.commit(messaging_module, dedupe_key, claim_token) do
      :ok -> :ok
      {:error, :stale_claim} -> Logger.warning("[Jido.Messaging.Ingest] Dedupe claim expired before commit")
    end

    result
  end

  defp finalize_dedupe_claim(messaging_module, dedupe_key, claim_token, {:error, _reason} = result) do
    _ = Jido.Messaging.Deduper.release(messaging_module, dedupe_key, claim_token)
    result
  end

  @doc """
  Process an incoming message without deduplication check.

  Use this when you've already verified the message is not a duplicate,
  or when deduplication is handled externally.
  """
  @spec ingest_incoming!(module(), module(), String.t(), incoming()) ::
          {:ok, Message.t(), context()} | {:error, ingest_error()}
  def ingest_incoming!(messaging_module, channel_module, bridge_id, incoming) do
    ingest_incoming!(messaging_module, channel_module, bridge_id, incoming, [])
  end

  @doc """
  Process an incoming message without deduplication check and with ingest policy options.
  """
  @spec ingest_incoming!(module(), module(), String.t(), incoming(), ingest_opts()) ::
          {:ok, Message.t(), context()} | {:error, ingest_error()}
  def ingest_incoming!(messaging_module, channel_module, bridge_id, incoming, opts)
      when is_list(opts) do
    channel_type = Jido.Messaging.AdapterBridge.channel_type(channel_module)
    bridge_id = to_string(bridge_id)
    external_room_id = incoming.external_room_id

    do_ingest(
      messaging_module,
      channel_module,
      channel_type,
      bridge_id,
      external_room_id,
      incoming,
      opts
    )
  end

  defp do_ingest(
         messaging_module,
         channel_module,
         channel_type,
         bridge_id,
         external_room_id,
         incoming,
         opts
       ) do
    raw_payload = incoming_raw_payload(incoming)

    with {:ok, verify_result} <-
           Security.verify_sender(messaging_module, channel_module, incoming, raw_payload, opts),
         {:ok, room} <- resolve_room(messaging_module, channel_type, bridge_id, incoming),
         {:ok, room_server} <- RoomSupervisor.get_or_start_room(messaging_module, room),
         {:ok, participant} <- resolve_participant(messaging_module, channel_type, incoming),
         msg_context <- build_msg_context(channel_module, bridge_id, incoming, room, participant, opts),
         {:ok, thread} <-
           resolve_thread_scope(
             messaging_module,
             channel_module,
             room_server,
             room,
             incoming,
             msg_context,
             opts
           ),
         {:ok, message} <-
           build_message(
             messaging_module,
             room,
             participant,
             thread,
             incoming,
             channel_type,
             bridge_id,
             opts
           ),
         message <- put_verify_metadata(message, verify_result),
         {:ok, policy_message} <- apply_policy_pipeline(message, msg_context, opts),
         {:ok, persisted_message} <- messaging_module.save_message_struct(policy_message) do
      thread = maybe_backfill_thread_root(messaging_module, thread, persisted_message)
      resolved_msg_context = MsgContext.with_resolved(msg_context, room, participant, persisted_message)
      resolved_msg_context = put_thread_context(resolved_msg_context, thread, persisted_message, external_room_id)

      context =
        Context.new(%{
          room: room,
          participant: participant,
          thread: thread,
          channel: channel_module,
          bridge_id: bridge_id,
          channel_type: channel_type,
          external_room_id: to_string(external_room_id),
          external_thread_id: resolved_msg_context.external_thread_id,
          delivery_external_room_id: resolved_msg_context.delivery_external_room_id || to_string(external_room_id),
          room_id: room.id,
          thread_id: resolved_msg_context.thread_id,
          participant_id: participant.id,
          instance_module: messaging_module,
          msg_context: resolved_msg_context
        })

      persist_session_route(
        messaging_module,
        resolved_msg_context,
        room,
        channel_type,
        bridge_id,
        external_room_id
      )

      ensure_thread_runner(messaging_module, room, room_server, thread)
      add_to_room_server(messaging_module, room, persisted_message, participant, context)

      Logger.debug("[Jido.Messaging.Ingest] Message #{persisted_message.id} ingested in room #{room.id}")

      Signal.emit_received(persisted_message, context)

      {:ok, persisted_message, context}
    end
  end

  defp persist_session_route(
         messaging_module,
         %MsgContext{} = msg_context,
         room,
         channel_type,
         bridge_id,
         external_room_id
       ) do
    route = %{
      channel_type: channel_type,
      bridge_id: bridge_id,
      room_id: room.id,
      thread_id: msg_context.thread_id || msg_context.external_thread_id,
      external_room_id: to_string(msg_context.delivery_external_room_id || external_room_id)
    }

    case SessionManager.set(messaging_module, SessionKey.from_context(msg_context), route) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Jido.Messaging.Ingest] Session route update skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp build_dedupe_key(channel_type, bridge_id, incoming) do
    external_message_id = Map.get(incoming, :external_message_id)
    external_room_id = Map.get(incoming, :external_room_id)

    if usable_external_id?(external_message_id) do
      {:ok, {channel_type, bridge_id, to_string(external_room_id), to_string(external_message_id)}}
    else
      :skip
    end
  end

  defp usable_external_id?(external_id) when is_binary(external_id), do: String.trim(external_id) != ""
  defp usable_external_id?(external_id), do: not is_nil(external_id)

  # Private helpers

  defp resolve_room(messaging_module, channel_type, bridge_id, incoming) do
    external_id = to_string(incoming.external_room_id)

    room_attrs = %{
      type: map_chat_type(Map.get(incoming, :chat_type)),
      name: Map.get(incoming, :chat_title)
    }

    messaging_module.get_or_create_room_by_external_binding(
      channel_type,
      bridge_id,
      external_id,
      room_attrs
    )
  end

  defp resolve_participant(messaging_module, channel_type, incoming) do
    external_id = to_string(incoming.external_user_id)

    participant_attrs = %{
      type: :human,
      identity: %{
        username: Map.get(incoming, :username),
        display_name: Map.get(incoming, :display_name)
      }
    }

    messaging_module.get_or_create_participant_by_external_id(
      channel_type,
      external_id,
      participant_attrs
    )
  end

  defp build_message(messaging_module, room, participant, thread, incoming, channel_type, bridge_id, opts) do
    with {:ok, content, media_metadata} <- build_content(incoming, opts) do
      reply_to_id = resolve_reply_to_id(messaging_module, channel_type, bridge_id, incoming)

      message_attrs = %{
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: content,
        reply_to_id: reply_to_id,
        external_id: Map.get(incoming, :external_message_id),
        external_reply_to_id: stringify_if_present(Map.get(incoming, :external_reply_to_id)),
        thread_id: thread && thread.id,
        external_thread_id: Map.get(incoming, :external_thread_id) || (thread && thread.external_thread_id),
        delivery_external_room_id:
          Map.get(incoming, :delivery_external_room_id) || (thread && thread.delivery_external_room_id),
        status: :sent,
        metadata: build_metadata(incoming, channel_type, bridge_id, media_metadata)
      }

      {:ok, Message.new(message_attrs)}
    end
  end

  defp build_msg_context(channel_module, bridge_id, incoming, room, participant, opts) do
    channel_module
    |> MsgContext.from_incoming(bridge_id, incoming)
    |> Normalizer.normalize(incoming, opts)
    |> then(fn msg_context ->
      %{msg_context | room_id: room.id, participant_id: participant.id}
    end)
  end

  defp resolve_thread_scope(
         messaging_module,
         channel_module,
         room_server,
         room,
         incoming,
         %MsgContext{} = msg_context,
         opts
       ) do
    case Map.get(incoming, :external_thread_id) do
      external_thread_id when is_binary(external_thread_id) ->
        get_or_create_thread(
          messaging_module,
          room.id,
          %{
            external_thread_id: external_thread_id,
            delivery_external_room_id:
              stringify_if_present(
                Map.get(incoming, :delivery_external_room_id) || Map.get(incoming, :external_room_id)
              ),
            root_external_message_id: stringify_if_present(Map.get(incoming, :external_reply_to_id)),
            metadata: %{source: :incoming_thread}
          }
        )
        |> maybe_assign_thread(messaging_module, room_server, room.id, msg_context)

      _ ->
        maybe_open_thread_for_assignment(
          messaging_module,
          channel_module,
          room_server,
          room,
          incoming,
          msg_context,
          opts
        )
    end
  end

  defp maybe_open_thread_for_assignment(
         messaging_module,
         channel_module,
         room_server,
         room,
         incoming,
         %MsgContext{} = msg_context,
         _opts
       ) do
    case resolve_target_agent(room_server, msg_context.agent_mentions) do
      {:ok, agent_id} ->
        if Map.get(incoming, :external_message_id) do
          with {:ok, result} <-
                 open_thread(
                   channel_module,
                   incoming.external_room_id,
                   incoming.external_message_id,
                   open_thread_opts(msg_context, incoming)
                 ),
               {:ok, thread} <-
                 get_or_create_thread(messaging_module, room.id, %{
                   external_thread_id: stringify_if_present(result_value(result, :external_thread_id)),
                   delivery_external_room_id:
                     stringify_if_present(
                       result_value(result, :delivery_external_room_id) || Map.get(incoming, :external_room_id)
                     ),
                   root_external_message_id: stringify_if_present(Map.get(incoming, :external_message_id)),
                   metadata: %{source: :opened_from_root}
                 }),
               {:ok, assigned_thread} <-
                 assign_resolved_thread(messaging_module, room_server, room.id, thread, agent_id) do
            {:ok, assigned_thread}
          else
            {:error, :unsupported} -> {:ok, nil}
            {:error, _reason} -> {:ok, nil}
          end
        else
          {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp open_thread(channel_module, external_room_id, external_message_id, opts) do
    cond do
      function_exported?(Jido.Chat.Adapter, :open_thread, 4) ->
        apply(Jido.Chat.Adapter, :open_thread, [
          channel_module,
          external_room_id,
          external_message_id,
          opts
        ])

      function_exported?(channel_module, :open_thread, 3) ->
        apply(channel_module, :open_thread, [external_room_id, external_message_id, opts])

      true ->
        {:error, :unsupported}
    end
  end

  defp get_or_create_thread(messaging_module, room_id, attrs) do
    external_thread_id = attrs[:external_thread_id]

    if is_binary(external_thread_id) do
      case messaging_module.get_thread_by_external_id(room_id, external_thread_id) do
        {:ok, thread} ->
          {:ok, merge_thread_fields(messaging_module, thread, attrs)}

        {:error, :not_found} ->
          messaging_module.save_thread(Map.put(attrs, :room_id, room_id))
      end
    else
      {:ok, nil}
    end
  end

  defp merge_thread_fields(messaging_module, %Thread{} = thread, attrs) do
    updated_thread =
      thread
      |> Map.merge(%{
        delivery_external_room_id: attrs[:delivery_external_room_id] || thread.delivery_external_room_id,
        root_external_message_id: attrs[:root_external_message_id] || thread.root_external_message_id,
        metadata: Map.merge(thread.metadata || %{}, attrs[:metadata] || %{}),
        updated_at: DateTime.utc_now()
      })

    {:ok, persisted_thread} = messaging_module.save_thread_struct(updated_thread)
    persisted_thread
  end

  defp maybe_assign_thread({:ok, nil}, _messaging_module, _room_server, _room_id, _msg_context), do: {:ok, nil}

  defp maybe_assign_thread({:ok, %Thread{} = thread}, messaging_module, room_server, room_id, msg_context) do
    case resolve_target_agent(room_server, msg_context.agent_mentions) do
      {:ok, agent_id} -> assign_resolved_thread(messaging_module, room_server, room_id, thread, agent_id)
      _ -> {:ok, thread}
    end
  end

  defp maybe_assign_thread({:error, _reason} = error, _messaging_module, _room_server, _room_id, _msg_context),
    do: error

  defp assign_resolved_thread(
         _messaging_module,
         _room_server,
         _room_id,
         %Thread{assigned_agent_id: agent_id} = thread,
         agent_id
       ),
       do: {:ok, thread}

  defp assign_resolved_thread(messaging_module, _room_server, room_id, %Thread{} = thread, agent_id) do
    case Jido.Messaging.assign_thread(messaging_module, room_id, thread.id, agent_id) do
      {:ok, assigned_thread} -> {:ok, assigned_thread}
      {:error, _reason} -> {:ok, thread}
    end
  end

  defp resolve_target_agent(_room_server, []), do: {:error, :no_agent_mentions}

  defp resolve_target_agent(room_server, [mention]) do
    normalized = String.downcase(mention)

    room_server
    |> RoomServer.list_agents()
    |> Enum.find(fn agent_spec ->
      normalized in Map.get(agent_spec, :mention_handles, [])
    end)
    |> case do
      nil -> {:error, :unknown_agent}
      agent_spec -> {:ok, agent_spec.agent_id}
    end
  end

  defp resolve_target_agent(_room_server, _mentions), do: {:error, :ambiguous_agent_mentions}

  defp open_thread_opts(msg_context, incoming) do
    [
      topic_name: build_topic_name(msg_context, incoming),
      agent_mentions: msg_context.agent_mentions,
      external_thread_id: Map.get(incoming, :external_thread_id)
    ]
  end

  defp build_topic_name(%MsgContext{body: body, agent_mentions: [agent | _]}, _incoming)
       when is_binary(body) do
    trimmed = body |> String.trim() |> String.slice(0, 40)
    "@" <> agent <> if(trimmed == "", do: "", else: " " <> trimmed)
  end

  defp build_topic_name(_msg_context, incoming) do
    "thread-" <> stringify_if_present(Map.get(incoming, :external_message_id) || Jido.Chat.ID.generate!())
  end

  defp result_value(result, key) when is_struct(result) do
    Map.get(result, key) ||
      case Map.get(result, :metadata) do
        metadata when is_map(metadata) -> Map.get(metadata, key)
        _ -> nil
      end
  end

  defp result_value(result, key) when is_map(result), do: Map.get(result, key) || Map.get(result, Atom.to_string(key))
  defp result_value(_result, _key), do: nil

  defp maybe_backfill_thread_root(_messaging_module, nil, _message), do: nil

  defp maybe_backfill_thread_root(messaging_module, %Thread{root_message_id: nil} = thread, message) do
    updated_thread = %{
      thread
      | root_message_id: message.id,
        root_external_message_id: thread.root_external_message_id || message.external_id,
        updated_at: DateTime.utc_now()
    }

    {:ok, persisted_thread} = messaging_module.save_thread_struct(updated_thread)
    persisted_thread
  end

  defp maybe_backfill_thread_root(_messaging_module, %Thread{} = thread, _message), do: thread

  defp put_thread_context(%MsgContext{} = msg_context, nil, message, external_room_id) do
    %{
      msg_context
      | thread_id: message.thread_id,
        external_thread_id: message.external_thread_id,
        delivery_external_room_id: message.delivery_external_room_id || stringify_if_present(external_room_id)
    }
  end

  defp put_thread_context(%MsgContext{} = msg_context, %Thread{} = thread, _message, external_room_id) do
    %{
      msg_context
      | thread_id: thread.id,
        external_thread_id: thread.external_thread_id,
        delivery_external_room_id: thread.delivery_external_room_id || stringify_if_present(external_room_id)
    }
  end

  defp ensure_thread_runner(_messaging_module, _room, _room_server, nil), do: :ok

  defp ensure_thread_runner(messaging_module, room, room_server, %Thread{assigned_agent_id: agent_id, id: thread_id})
       when is_binary(agent_id) and is_binary(thread_id) do
    case RoomServer.get_agent(room_server, agent_id) do
      {:ok, agent_spec} ->
        _ = Jido.Messaging.assign_thread(messaging_module, room.id, thread_id, agent_id)
        _ = agent_spec
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_thread_runner(_messaging_module, _room, _room_server, _thread), do: :ok

  defp resolve_reply_to_id(messaging_module, channel_type, bridge_id, incoming) do
    external_reply_to_id = Map.get(incoming, :external_reply_to_id)

    if external_reply_to_id do
      case messaging_module.get_message_by_external_id(channel_type, bridge_id, external_reply_to_id) do
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
        Logger.warning("[Jido.Messaging.Ingest] Media policy rejection: #{inspect(reason)}")
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

  defp build_metadata(incoming, channel_type, bridge_id, media_metadata) do
    %{
      external_message_id: Map.get(incoming, :external_message_id),
      timestamp: Map.get(incoming, :timestamp),
      channel: channel_type,
      bridge_id: bridge_id,
      username: Map.get(incoming, :username),
      display_name: Map.get(incoming, :display_name)
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

    with {:ok, context_policy_state} <- run_context_policy_controls(msg_context, opts, initial_state),
         {:ok, gating_state} <- run_gating(msg_context, opts, context_policy_state),
         {:ok, moderated_message, policy_state} <- run_moderation(message, opts, gating_state) do
      {:ok, put_policy_metadata(moderated_message, policy_state)}
    end
  end

  defp run_context_policy_controls(%MsgContext{} = msg_context, opts, state) do
    with {:ok, state} <- enforce_require_mention(msg_context, opts, state),
         {:ok, state} <- enforce_allowed_prefixes(msg_context, opts, state) do
      {:ok, state}
    end
  end

  defp enforce_require_mention(%MsgContext{} = msg_context, opts, state) do
    if Keyword.get(opts, :require_mention, false) and not msg_context.was_mentioned do
      description = "Message must mention a configured target"
      decision = build_decision(:gating, :ingest_context_policy, :deny, 0, :mention_required, description)
      emit_policy_telemetry(decision)
      {:error, {:policy_denied, :gating, :mention_required, description}}
    else
      {:ok, state}
    end
  end

  defp enforce_allowed_prefixes(%MsgContext{} = msg_context, opts, state) do
    allowed_prefixes = normalize_prefixes(Keyword.get(opts, :allowed_prefixes))

    case {allowed_prefixes, msg_context.command} do
      {[], _} ->
        {:ok, state}

      {_, %{status: :ok, prefix: prefix}} when is_binary(prefix) ->
        if prefix in allowed_prefixes do
          {:ok, state}
        else
          description = "Command prefix is not allowed by ingest policy"

          decision =
            build_decision(
              :gating,
              :ingest_context_policy,
              :deny,
              0,
              :command_prefix_not_allowed,
              description
            )

          emit_policy_telemetry(decision)
          {:error, {:policy_denied, :gating, :command_prefix_not_allowed, description}}
        end

      _ ->
        {:ok, state}
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
        thread_id: original.thread_id,
        external_thread_id: original.external_thread_id,
        delivery_external_room_id: original.delivery_external_room_id,
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

  defp normalize_prefixes(nil), do: []
  defp normalize_prefixes(prefixes) when is_list(prefixes), do: CommandParser.normalize_prefixes(prefixes)
  defp normalize_prefixes(_), do: []

  defp add_to_room_server(messaging_module, room, message, participant, context) do
    case RoomSupervisor.get_or_start_room(messaging_module, room) do
      {:ok, pid} ->
        RoomServer.add_message(pid, message, context)
        RoomServer.add_participant(pid, participant)

      {:error, reason} ->
        Logger.warning("[Jido.Messaging.Ingest] Failed to start room server: #{inspect(reason)}")
    end
  end

  defp stringify_if_present(nil), do: nil
  defp stringify_if_present(value) when is_binary(value), do: value
  defp stringify_if_present(value), do: to_string(value)
end
