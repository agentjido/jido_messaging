defmodule Jido.Messaging.Ingest.ThreadScope do
  @moduledoc false
  require Logger

  alias Jido.Messaging.{Message, MsgContext, RoomServer, Signal, Thread}

  @doc false
  @spec resolve(module(), pid(), Jido.Chat.Room.t(), map(), MsgContext.t()) ::
          {:ok, Thread.t() | nil} | {:error, term()}
  def resolve(
        messaging_module,
        room_server,
        room,
        incoming,
        %MsgContext{} = msg_context
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
        {:ok, nil}
    end
  end

  # The canonical message is accepted before automatic provider work starts.
  # Later thread-link failure cannot release that accepted message for replay.
  @doc false
  @spec complete(
          module(),
          module(),
          pid(),
          Jido.Chat.Room.t(),
          map(),
          MsgContext.t(),
          Thread.t() | nil,
          Message.t(),
          keyword()
        ) ::
          {Message.t(), Thread.t() | nil}
  def complete(instance, adapter, server, room, incoming, context, thread, message, opts) do
    thread_result =
      if thread,
        do: {:ok, thread},
        else: maybe_open_thread_for_assignment(instance, adapter, server, room, incoming, context, opts)

    with {:ok, thread} <- thread_result,
         thread <- maybe_backfill_thread_root(instance, thread, message),
         {:ok, saved} <- persist_thread_link(instance, message, thread) do
      {saved, thread}
    else
      {:error, _} -> thread_scope_failed(instance, message, context, opts)
    end
  rescue
    _ -> thread_scope_failed(instance, message, context, opts)
  catch
    _, _ -> thread_scope_failed(instance, message, context, opts)
  end

  defp persist_thread_link(_instance, message, nil), do: {:ok, message}
  defp persist_thread_link(_instance, %{thread_id: id} = message, %{id: id}), do: {:ok, message}

  defp persist_thread_link(instance, message, thread) do
    instance.save_message_struct(%{
      message
      | thread_id: thread.id,
        external_thread_id: thread.external_thread_id,
        delivery_external_room_id: thread.delivery_external_room_id
    })
  end

  defp thread_scope_failed(instance, message, context, opts) do
    Signal.emit_failed(message.room_id, :persistence_failed, %{
      instance_module: instance,
      message_id: message.id,
      bridge_id: context.bridge_id,
      parent_signal: opts[:parent_signal]
    })

    Logger.warning("[Jido.Messaging.Ingest] Accepted message thread link failed")
    {message, nil}
  end

  defp maybe_open_thread_for_assignment(
         messaging_module,
         channel_module,
         room_server,
         room,
         incoming,
         %MsgContext{} = msg_context,
         opts
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
                   |> Keyword.put(:instance_module, messaging_module)
                   |> Keyword.put(:bridge_id, msg_context.bridge_id)
                   |> Keyword.put(:parent_signal, opts[:parent_signal])
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
    Jido.Messaging.AdapterBridge.operation(
      channel_module,
      :open_thread,
      %{"room_id" => to_string(external_room_id), "message_id" => to_string(external_message_id)},
      opts
    )
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

  @doc false
  @spec put_context(MsgContext.t(), Thread.t() | nil, Message.t(), term()) :: MsgContext.t()
  def put_context(%MsgContext{} = msg_context, nil, message, external_room_id) do
    %{
      msg_context
      | thread_id: message.thread_id,
        external_thread_id: message.external_thread_id,
        delivery_external_room_id: message.delivery_external_room_id || stringify_if_present(external_room_id)
    }
  end

  @doc false
  def put_context(%MsgContext{} = msg_context, %Thread{} = thread, _message, external_room_id) do
    %{
      msg_context
      | thread_id: thread.id,
        external_thread_id: thread.external_thread_id,
        delivery_external_room_id: thread.delivery_external_room_id || stringify_if_present(external_room_id)
    }
  end

  @doc false
  @spec ensure_runner(module(), Jido.Chat.Room.t(), pid(), Thread.t() | nil) :: :ok
  def ensure_runner(_messaging_module, _room, _room_server, nil), do: :ok

  @doc false
  def ensure_runner(messaging_module, room, room_server, %Thread{assigned_agent_id: agent_id, id: thread_id})
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

  @doc false
  def ensure_runner(_messaging_module, _room, _room_server, _thread), do: :ok

  defp stringify_if_present(nil), do: nil
  defp stringify_if_present(value) when is_binary(value), do: value
  defp stringify_if_present(value), do: to_string(value)
end
