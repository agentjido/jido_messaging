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
  alias Jido.Messaging.Ingest.{Policy, Prepared, ThreadScope}

  alias Jido.Messaging.{
    Authorship,
    Context,
    Identity,
    Message,
    MediaPolicy,
    MsgContext,
    MsgContext.Normalizer,
    RoomServer,
    RoomSupervisor,
    Security,
    SessionKey,
    SessionManager,
    Signal
  }

  @type incoming :: map()
  @type policy_stage :: :gating | :moderation
  @type policy_denial :: {:policy_denied, policy_stage(), atom(), String.t()}
  @type security_denial :: Security.security_denial()
  @type ingest_error :: policy_denial() | security_denial() | term()
  @type ingest_opts :: keyword()

  @type context :: Context.t()

  @doc false
  @spec accept_fact(module(), Jido.Chat.Binding.t(), Jido.Signal.t()) ::
          {:ok, Message.t(), context()} | {:ok, :duplicate} | {:error, term()}
  def accept_fact(instance, binding, %Jido.Signal{type: "jido.chat.message.received"} = signal) do
    data = signal.data
    sender = data["sender"]

    author = %{
      user_id: sender["id"],
      user_name: sender["username"] || sender["id"],
      full_name: sender["display_name"],
      is_bot: sender["is_bot"] || false,
      is_self: sender["is_self"] || false
    }

    mentions =
      Enum.map(data["mention_details"] || [], fn item ->
        %{user_id: item["id"], username: item["username"], offset: item["offset"], length: item["length"]}
      end)

    kind = Enum.find([:direct, :group, :channel, :thread], &(Atom.to_string(&1) == data["conversation_kind"]))

    with {:ok, media} <- resolve_fact_media(binding, data["media"] || []) do
      incoming = %{
        external_room_id: data["room_id"],
        external_message_id: data["message_id"],
        external_user_id: sender["id"],
        external_thread_id: data["thread_id"],
        external_reply_to_id: data["reply_to_id"],
        text: data["text"],
        author: author,
        username: sender["username"],
        display_name: sender["display_name"],
        chat_type: kind,
        chat_title: data["conversation_name"],
        media: media,
        mentions: mentions,
        was_mentioned: data["mentioned"] || false,
        raw: %{},
        signal_media: data["media"],
        reply_context: data["reply_context"],
        provider_self: sender["is_self"] || false,
        timestamp: provider_timestamp(data["timestamp"])
      }

      ingest_incoming(instance, binding.adapter, binding.id, incoming, parent_signal: signal, emit_received: false)
    end
  end

  defp resolve_fact_media(binding, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, media} ->
      with true <- item["resource_ref"]["kind"] in ["media", "file"],
           {:ok, private} <- Jido.Chat.resolve_resource(binding, item["resource_ref"]),
           true <- is_map(private) and not is_struct(private) do
        kind = Enum.find([:image, :audio, :video, :file], &(Atom.to_string(&1) == item["kind"]))

        payload =
          Enum.reduce(
            [
              :url,
              :data,
              :media_type,
              :filename,
              :size_bytes,
              :width,
              :height,
              :duration,
              :thumbnail_url,
              :alt_text,
              :transcript
            ],
            %{},
            fn field, acc ->
              case Map.get(private, field) || Map.get(private, Atom.to_string(field)) do
                nil -> acc
                value -> Map.put(acc, field, value)
              end
            end
          )
          |> Map.put(:kind, kind)
          |> Map.put_new(:media_type, item["media_type"])
          |> Map.put_new(:filename, item["name"])
          |> Map.put_new(:alt_text, item["caption"])
          |> Map.put_new(:transcript, item["caption"])

        {:cont, {:ok, media ++ [payload]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, Jido.Chat.Signal.Policy.error(:invalid_resource)}
      end
    end)
  end

  defp provider_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} -> DateTime.to_unix(timestamp, :millisecond)
      _ -> nil
    end
  end

  defp provider_timestamp(_), do: nil

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
      {:error, :outcome_unknown} ->
        Jido.Chat.Signal.Policy.error(:request_outcome_unknown)

      :duplicate ->
        Logger.debug("[Jido.Messaging.Ingest] Duplicate message ignored: #{inspect(dedupe_key)}")
        {:ok, :duplicate}

      {:ok, claim_token} ->
        result =
          safely(fn ->
            do_ingest(
              messaging_module,
              channel_module,
              channel_type,
              bridge_id,
              external_room_id,
              incoming,
              opts
            )
          end)

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

  defp finalize_dedupe_claim(
         messaging_module,
         dedupe_key,
         claim_token,
         {:error, %Jido.Chat.Errors.Contract{code: :request_outcome_unknown}} = result
       ) do
    _ = Jido.Messaging.Deduper.retain_unknown(messaging_module, dedupe_key, claim_token)
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
    with {:ok, prepared} <-
           prepare_incoming(messaging_module, channel_module, channel_type, bridge_id, external_room_id, incoming, opts),
         {:ok, message} <- Policy.evaluate(prepared.message, prepared.msg_context, prepared.opts),
         {:ok, persisted_message} <- commit_message(prepared.instance, message) do
      publish_accepted(prepared, persisted_message)
    end
  end

  defp prepare_incoming(
         messaging_module,
         channel_module,
         channel_type,
         bridge_id,
         external_room_id,
         incoming,
         opts
       ) do
    incoming = Map.put(incoming, :external_user_id, external_user_id(incoming))
    raw_payload = incoming_raw_payload(incoming)

    with {:ok, verify_result} <-
           Security.verify_sender(messaging_module, channel_module, incoming, raw_payload, opts),
         {:ok, room} <- resolve_room(messaging_module, channel_type, bridge_id, incoming),
         {:ok, room_server} <- RoomSupervisor.get_or_start_room(messaging_module, room),
         {:ok, participant} <- resolve_participant(messaging_module, channel_type, bridge_id, incoming),
         {:ok, authorship} <-
           resolve_authorship(
             messaging_module,
             participant,
             channel_type,
             bridge_id,
             incoming,
             verify_result,
             opts
           ),
         msg_context <- build_msg_context(channel_module, bridge_id, incoming, room, participant, opts),
         {:ok, thread} <-
           ThreadScope.resolve(
             messaging_module,
             room_server,
             room,
             incoming,
             msg_context
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
         message <- Identity.put_authorship(message, authorship),
         message <- put_verify_metadata(message, verify_result) do
      {:ok,
       %Prepared{
         instance: messaging_module,
         adapter: channel_module,
         channel_type: channel_type,
         bridge_id: bridge_id,
         external_room_id: external_room_id,
         incoming: incoming,
         opts: opts,
         room: room,
         room_server: room_server,
         participant: participant,
         msg_context: msg_context,
         thread: thread,
         message: message
       }}
    end
  end

  # Only committed messages enter this stage. Observation failures cannot
  # release their dedupe claim or change their successful acceptance result.
  defp publish_accepted(
         %Prepared{
           instance: messaging_module,
           adapter: channel_module,
           channel_type: channel_type,
           bridge_id: bridge_id,
           external_room_id: external_room_id,
           incoming: incoming,
           opts: opts,
           room: room,
           room_server: room_server,
           participant: participant,
           msg_context: msg_context,
           thread: thread
         },
         persisted_message
       ) do
    {persisted_message, thread} =
      ThreadScope.complete(
        messaging_module,
        channel_module,
        room_server,
        room,
        incoming,
        msg_context,
        thread,
        persisted_message,
        opts
      )

    resolved_msg_context = MsgContext.with_resolved(msg_context, room, participant, persisted_message)
    resolved_msg_context = ThreadScope.put_context(resolved_msg_context, thread, persisted_message, external_room_id)

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
        parent_signal: opts[:parent_signal],
        msg_context: resolved_msg_context
      })

    after_accept(persisted_message, context, fn ->
      persist_session_route(
        messaging_module,
        resolved_msg_context,
        room,
        channel_type,
        bridge_id,
        external_room_id
      )
    end)

    after_accept(persisted_message, context, fn ->
      ThreadScope.ensure_runner(messaging_module, room, room_server, thread)
    end)

    after_accept(persisted_message, context, fn ->
      add_to_room_server(messaging_module, room, persisted_message, participant, context)
    end)

    Logger.debug("[Jido.Messaging.Ingest] Message #{persisted_message.id} ingested in room #{room.id}")

    if Keyword.get(opts, :emit_received, true),
      do: after_accept(persisted_message, context, fn -> Signal.emit_received(persisted_message, context) end)

    {:ok, persisted_message, context}
  end

  # A store may fail after its write. Read the same prepared ID before deciding
  # whether acceptance failed; never build and write a second message here.
  defp commit_message(instance, %Message{id: id} = message) do
    case safely(fn -> instance.save_message_struct(message) end) do
      {:ok, %Message{id: ^id} = saved} ->
        {:ok, saved}

      result ->
        case safely(fn -> instance.get_message(id) end) do
          {:ok, %Message{id: ^id} = saved} ->
            {:ok, saved}

          {:error, :not_found} ->
            if match?({:error, _}, result), do: result, else: Jido.Chat.Signal.Policy.error(:handler_failed)

          _ ->
            Jido.Chat.Signal.Policy.error(:request_outcome_unknown)
        end
    end
  end

  defp after_accept(message, context, fun) do
    case safely(fun) do
      {:error, _} ->
        Logger.warning("[Jido.Messaging.Ingest] Accepted message runtime observation failed")

        safely(fn ->
          Signal.emit_failed(
            message.room_id,
            :observation_failed,
            Map.put(Map.from_struct(context), :message_id, message.id)
          )
        end)

      _ ->
        :ok
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> Jido.Chat.Signal.Policy.error(:handler_failed)
  catch
    _, _ -> Jido.Chat.Signal.Policy.error(:handler_failed)
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

  defp resolve_participant(messaging_module, channel_type, bridge_id, incoming) do
    author = Map.get(incoming, :author)
    external_id = external_user_id(incoming)
    username = first_present(author_value(author, :user_name), Map.get(incoming, :username))
    display_name = first_present(author_value(author, :full_name), Map.get(incoming, :display_name))
    email = author_value(author, :email)

    identity = %{username: username, display_name: display_name}
    identity = if blank_value?(email), do: identity, else: Map.put(identity, :email, email)

    participant_attrs =
      %{
        type: author_type(author),
        identity: identity
      }
      |> maybe_put_stable_author_id(author_value(author, :id))

    messaging_module.get_or_create_participant_by_external_id(
      channel_type,
      bridge_id,
      to_string(external_id),
      participant_attrs
    )
  end

  defp resolve_authorship(
         messaging_module,
         participant,
         channel_type,
         bridge_id,
         incoming,
         verify_result,
         opts
       ) do
    external_id = external_user_id(incoming)

    if blank_value?(external_id) do
      {:ok, Authorship.asserted(participant.id)}
    else
      runtime = messaging_module.__jido_messaging__(:runtime)

      with {:ok, _principal, _binding, authorship} <-
             Jido.Messaging.resolve_authorship(
               runtime,
               participant,
               channel_type,
               bridge_id,
               external_id,
               verify_result,
               runtime_execution_id: Keyword.get(opts, :runtime_execution_id)
             ) do
        {:ok, authorship}
      end
    end
  end

  defp author_value(author, key) when is_map(author), do: Map.get(author, key) || Map.get(author, Atom.to_string(key))
  defp author_value(_author, _key), do: nil

  defp external_user_id(incoming) do
    first_present(
      Map.get(incoming, :external_user_id),
      author_value(Map.get(incoming, :author), :user_id)
    )
  end

  defp first_present(value, fallback) do
    if blank_value?(value), do: fallback, else: value
  end

  defp blank_value?(nil), do: true
  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(_value), do: false

  defp maybe_put_stable_author_id(attrs, author_id) do
    if blank_value?(author_id), do: attrs, else: Map.put(attrs, :id, author_id)
  end

  defp author_type(author) do
    cond do
      author_value(author, :is_system) == true -> :system
      author_value(author, :is_bot) == true -> :agent
      true -> :human
    end
  end

  defp build_message(messaging_module, room, participant, thread, incoming, channel_type, bridge_id, opts) do
    with {:ok, content, media_metadata} <- build_content(incoming, opts) do
      reply_to_id = resolve_reply_to_id(messaging_module, channel_type, bridge_id, room.id, incoming)

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
        metadata:
          build_metadata(incoming, channel_type, bridge_id, media_metadata)
          |> Map.put(:signal_media, incoming[:signal_media])
          |> Map.put(:reply_context, incoming[:reply_context])
          |> Map.put(:provider_self, incoming[:provider_self] || false)
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

  defp resolve_reply_to_id(messaging_module, channel_type, bridge_id, room_id, incoming) do
    external_reply_to_id = Map.get(incoming, :external_reply_to_id)

    if external_reply_to_id do
      case messaging_module.get_message_by_external_id(channel_type, bridge_id, external_reply_to_id, room_id) do
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

  defp map_chat_type(:thread), do: :thread
  defp map_chat_type(:direct), do: :direct
  defp map_chat_type(:private), do: :direct
  defp map_chat_type(:group), do: :group
  defp map_chat_type(:supergroup), do: :group
  defp map_chat_type(:channel), do: :channel
  defp map_chat_type(_), do: :direct

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
