defmodule Jido.Messaging.Events do
  @moduledoc "Typed Messaging facts from committed records and explicit runtime events."

  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.Message
  alias Jido.Messaging.Signal.{Context, Identity}

  @fact_fields Jason.decode!(
                 ~S|{"jido.messaging.room.message_added":["message","message_id","room_id","thread_id","reply_to_id","sender_id","text","role","status","external_room_id","external_message_id","bridge_id"],"jido.messaging.message.received":["message","message_id","room_id","thread_id","reply_to_id","sender_id","text","role","status","external_room_id","external_message_id","bridge_id"],"jido.messaging.message.sent":["message","message_id","room_id","thread_id","reply_to_id","sender_id","text","role","status","external_room_id","external_message_id","bridge_id"],"jido.messaging.message.failed":["room_id","message_id","bridge_id","code"],"jido.messaging.room.created":["room_id","name","kind"],"jido.messaging.room.participant_joined":["room_id","participant_id","reason"],"jido.messaging.room.participant_left":["room_id","participant_id","reason"],"jido.messaging.participant.presence_changed":["room_id","participant_id","presence"],"jido.messaging.participant.typing":["room_id","participant_id","typing","thread_id"],"jido.messaging.message.reaction_added":["room_id","message_id","participant_id","reaction"],"jido.messaging.message.reaction_removed":["room_id","message_id","participant_id","reaction"],"jido.messaging.message.delivered":["room_id","message_id","participant_id","timestamp"],"jido.messaging.message.read":["room_id","message_id","participant_id","timestamp"],"jido.messaging.thread.created":["room_id","thread_id","message_id","participant_id"],"jido.messaging.thread.reply_added":["room_id","thread_id","message_id","participant_id"],"jido.messaging.agent.triggered":["room_id","agent_id","message_id","thread_id","code"],"jido.messaging.agent.started":["room_id","agent_id","message_id","thread_id","code"],"jido.messaging.agent.completed":["room_id","agent_id","message_id","thread_id","code"],"jido.messaging.agent.failed":["room_id","agent_id","message_id","thread_id","code"],"jido.messaging.instance.started":["instance_id","bridge_id","code"],"jido.messaging.instance.connecting":["instance_id","bridge_id","code"],"jido.messaging.instance.connected":["instance_id","bridge_id","code"],"jido.messaging.instance.disconnected":["instance_id","bridge_id","code"],"jido.messaging.instance.stopped":["instance_id","bridge_id","code"],"jido.messaging.instance.error":["instance_id","bridge_id","code"],"jido.messaging.membership.observed":["binding_id","external_room_id","room_id","participant_id","actor_id","bot_self","transition","evidence","previous","current"],"jido.messaging.thread.changed":["room_id","thread_id","message_id","participant_id","change"]}|
               )
  @type event_type :: atom() | String.t()

  @doc "Builds a registered fact from a committed canonical message."
  @spec message_added(module(), Message.t(), keyword() | map()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def message_added(instance, message, opts \\ []),
    do: new(:message_added, instance, message.room_id, message_data(message, opts), opts)

  @doc "Builds a received fact from a committed canonical message."
  @spec message_received(module(), Message.t(), keyword() | map()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def message_received(instance, message, opts \\ []),
    do: new(:message_received, instance, message.room_id, message_data(message, opts), opts)

  @doc "Builds a sent fact from a committed canonical message."
  @spec message_sent(module(), Message.t(), keyword() | map()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def message_sent(instance, message, opts \\ []),
    do: new(:message_sent, instance, message.room_id, message_data(message, opts), opts)

  @doc "Builds a failure fact without a private error value."
  @spec message_failed(module(), String.t(), term(), keyword() | map()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def message_failed(instance, room, reason, opts \\ []) do
    opts = options(opts)

    new(
      :message_failed,
      instance,
      room,
      %{room_id: room, code: failure_code(reason), message_id: opts[:message_id], bridge_id: opts[:bridge_id]},
      opts
    )
  end

  @doc "Builds a registered reaction fact."
  @spec reaction_added(module(), Message.t(), String.t(), String.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def reaction_added(instance, message, participant, reaction, opts \\ []),
    do: reaction(:reaction_added, instance, message, participant, reaction, opts)

  @doc "Builds a registered reaction removal fact."
  @spec reaction_removed(module(), Message.t(), String.t(), String.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def reaction_removed(instance, message, participant, reaction, opts \\ []),
    do: reaction(:reaction_removed, instance, message, participant, reaction, opts)

  @doc "Builds a registered room fact from private runtime data."
  @spec room_event(module(), event_type(), String.t() | nil, map(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def room_event(instance, event, room, data, opts \\ []),
    do: new(event, instance, room, Map.put(data, :room_id, room), opts)

  @doc false
  @spec new(event_type(), module() | nil, String.t() | nil, map(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def new(event, instance, room, data, opts \\ []) when is_map(data) do
    type = type_for(event)
    opts = options(opts)
    definition = Enum.find(Jido.Messaging.signal_definitions(), &(&1.type() == type and &1.__signal_kind__() == :fact))

    with true <- not is_nil(definition),
         true <- is_nil(opts[:dataschema]),
         {:ok, signal} <-
           definition.new(project(type, data, room, opts),
             source: source(instance, opts),
             subject: Identity.room_subject(room)
           ),
         {:ok, signal} <- Context.attach(signal, opts),
         {:ok, signal} <- Policy.validate(signal) do
      {:ok, signal}
    else
      {:error, _} = error -> error
      _ -> Policy.error(:unknown_definition)
    end
  rescue
    _ -> Policy.error(:invalid_request)
  end

  @doc "Returns the stable source for a runtime instance."
  @spec source(module() | nil, keyword()) :: String.t()
  def source(instance, opts \\ []) do
    id = opts[:instance_id] || if(is_nil(instance), do: "local", else: Atom.to_string(instance))
    Identity.instance_source(id)
  end

  @spec type_for(String.t() | event_type()) :: String.t()
  @doc """
  Returns the CloudEvent type string for a messaging event atom or custom type string.
  """
  def type_for(type) when is_binary(type), do: type
  def type_for(:message_added), do: "jido.messaging.room.message_added"
  def type_for(:message_received), do: "jido.messaging.message.received"
  def type_for(:message_sent), do: "jido.messaging.message.sent"
  def type_for(:message_failed), do: "jido.messaging.message.failed"
  def type_for(:room_created), do: "jido.messaging.room.created"
  def type_for(:participant_joined), do: "jido.messaging.room.participant_joined"
  def type_for(:participant_left), do: "jido.messaging.room.participant_left"
  def type_for(:presence_changed), do: "jido.messaging.participant.presence_changed"
  def type_for(:typing), do: "jido.messaging.participant.typing"
  def type_for(:reaction_added), do: "jido.messaging.message.reaction_added"
  def type_for(:reaction_removed), do: "jido.messaging.message.reaction_removed"
  def type_for(:message_delivered), do: "jido.messaging.message.delivered"
  def type_for(:message_read), do: "jido.messaging.message.read"
  def type_for(:thread_created), do: "jido.messaging.thread.created"
  def type_for(:thread_reply_added), do: "jido.messaging.thread.reply_added"
  def type_for(event_type) when is_atom(event_type), do: "jido.messaging.room.#{event_type}"

  @spec telemetry_event_for(String.t() | event_type()) :: [atom()]
  @doc """
  Returns the telemetry event name associated with a messaging event type.
  """
  def telemetry_event_for("jido.messaging.message.received"), do: telemetry_event_for(:message_received)
  def telemetry_event_for("jido.messaging.message.sent"), do: telemetry_event_for(:message_sent)
  def telemetry_event_for("jido.messaging.message.failed"), do: telemetry_event_for(:message_failed)
  def telemetry_event_for("jido.messaging.room.message_added"), do: telemetry_event_for(:message_added)
  def telemetry_event_for("jido.messaging.room.created"), do: telemetry_event_for(:room_created)
  def telemetry_event_for("jido.messaging.room.participant_joined"), do: telemetry_event_for(:participant_joined)
  def telemetry_event_for("jido.messaging.room.participant_left"), do: telemetry_event_for(:participant_left)
  def telemetry_event_for("jido.messaging.participant.presence_changed"), do: telemetry_event_for(:presence_changed)
  def telemetry_event_for("jido.messaging.participant.typing"), do: telemetry_event_for(:typing)
  def telemetry_event_for("jido.messaging.message.reaction_added"), do: telemetry_event_for(:reaction_added)
  def telemetry_event_for("jido.messaging.message.reaction_removed"), do: telemetry_event_for(:reaction_removed)
  def telemetry_event_for("jido.messaging.message.delivered"), do: telemetry_event_for(:message_delivered)
  def telemetry_event_for("jido.messaging.message.read"), do: telemetry_event_for(:message_read)
  def telemetry_event_for("jido.messaging.thread.created"), do: telemetry_event_for(:thread_created)
  def telemetry_event_for("jido.messaging.thread.reply_added"), do: telemetry_event_for(:thread_reply_added)
  def telemetry_event_for("jido.messaging.agent.triggered"), do: [:jido_messaging, :agent, :triggered]
  def telemetry_event_for("jido.messaging.agent.started"), do: [:jido_messaging, :agent, :started]
  def telemetry_event_for("jido.messaging.agent.completed"), do: [:jido_messaging, :agent, :completed]
  def telemetry_event_for("jido.messaging.agent.failed"), do: [:jido_messaging, :agent, :failed]
  def telemetry_event_for(type) when is_binary(type), do: [:jido_messaging, :signal, :custom]

  def telemetry_event_for(:message_added), do: [:jido_messaging, :room, :message_added]
  def telemetry_event_for(:message_received), do: [:jido_messaging, :message, :received]
  def telemetry_event_for(:message_sent), do: [:jido_messaging, :message, :sent]
  def telemetry_event_for(:message_failed), do: [:jido_messaging, :message, :failed]
  def telemetry_event_for(:room_created), do: [:jido_messaging, :room, :created]
  def telemetry_event_for(:participant_joined), do: [:jido_messaging, :room, :participant_joined]
  def telemetry_event_for(:participant_left), do: [:jido_messaging, :room, :participant_left]
  def telemetry_event_for(:presence_changed), do: [:jido_messaging, :participant, :presence_changed]
  def telemetry_event_for(:typing), do: [:jido_messaging, :participant, :typing]
  def telemetry_event_for(:reaction_added), do: [:jido_messaging, :message, :reaction_added]
  def telemetry_event_for(:reaction_removed), do: [:jido_messaging, :message, :reaction_removed]
  def telemetry_event_for(:message_delivered), do: [:jido_messaging, :message, :delivered]
  def telemetry_event_for(:message_read), do: [:jido_messaging, :message, :read]
  def telemetry_event_for(:thread_created), do: [:jido_messaging, :thread, :created]
  def telemetry_event_for(:thread_reply_added), do: [:jido_messaging, :thread, :reply_added]
  def telemetry_event_for(event_type) when is_atom(event_type), do: [:jido_messaging, :room, event_type]

  @doc "Builds the safe public message summary and canonical identity fields."
  @spec message_data(Message.t(), keyword() | map()) :: map()
  def message_data(%Message{} = message, opts \\ []) do
    opts = options(opts)

    %{
      "message" => message_summary(message),
      "message_id" => message.id,
      "room_id" => message.room_id,
      "sender_id" => message.sender_id,
      "text" => text(message.content),
      "role" => Atom.to_string(message.role),
      "status" => Atom.to_string(message.status),
      "thread_id" => message.thread_id,
      "reply_to_id" => message.reply_to_id,
      "external_message_id" => message.external_id,
      "external_room_id" => opts[:external_room_id],
      "bridge_id" => opts[:bridge_id]
    }
    |> compact()
  end

  @doc "Builds the safe public subset of a canonical message record."
  @spec message_summary(Message.t()) :: map()
  def message_summary(%Message{} = message) do
    %{
      "id" => message.id,
      "room_id" => message.room_id,
      "text" => text(message.content),
      "sender" => %{"id" => message.sender_id},
      "role" => Atom.to_string(message.role),
      "status" => Atom.to_string(message.status),
      "thread_id" => message.thread_id,
      "reply_to_id" => message.reply_to_id,
      "timestamp" => scalar(message.inserted_at),
      "media" => Map.get(message.metadata, :signal_media)
    }
    |> compact()
  end

  defp project(type, data, room, opts) do
    data = enrich(type, data, room, opts)
    Map.new(@fact_fields[type], fn field -> {field, scalar(value(data, field))} end) |> compact_fact(type)
  end

  defp enrich(type, data, room, opts) do
    data = data |> Map.delete("room_id") |> Map.put(:room_id, room)

    data =
      if match?(%Message{}, value(data, "message")),
        do: Map.merge(data, message_data(value(data, "message"), opts)),
        else: data

    cond do
      type in [type_for(:participant_joined), type_for(:participant_left)] ->
        data
        |> Map.put(:participant_id, value(data, "participant_id") || record_id(value(data, "participant")))
        |> Map.put(:reason, value(data, "reason") || opts[:reason] || "observed")

      type == type_for(:presence_changed) ->
        Map.put(data, :presence, value(data, "presence") || value(data, "to"))

      type == type_for(:typing) ->
        Map.put(data, :typing, first(data, ["typing", "is_typing"]))

      type in [type_for(:thread_created), type_for(:thread_reply_added)] ->
        Map.put(data, :thread_id, value(data, "thread_id") || value(data, "root_message_id"))

      true ->
        data
    end
  end

  defp reaction(event, instance, message, participant, reaction, opts),
    do:
      room_event(
        instance,
        event,
        message.room_id,
        %{message_id: message.id, participant_id: participant, reaction: reaction},
        opts
      )

  defp first(data, keys) do
    result =
      Enum.find_value(keys, fn key ->
        case value(data, key) do
          nil -> nil
          value -> {:present, value}
        end
      end)

    case result do
      {:present, value} -> value
      _ -> nil
    end
  end

  defp value(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(data, fn {field, value} ->
          if is_atom(field) and Atom.to_string(field) == key, do: {:present, value}
        end)
        |> unwrap()
    end
  end

  defp unwrap({:present, value}), do: value
  defp unwrap(_), do: nil
  defp record_id(value) when is_map(value), do: Map.get(value, :id) || Map.get(value, "id")
  defp record_id(_), do: nil
  defp scalar(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp scalar(value) when is_atom(value) and not is_nil(value) and not is_boolean(value), do: Atom.to_string(value)
  defp scalar(value), do: value

  defp compact_fact(map, "jido.messaging.membership.observed"),
    do: Map.reject(map, fn {key, value} -> is_nil(value) and key not in ["room_id", "previous"] end)

  defp compact_fact(map, _type), do: compact(map)

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp text(content),
    do:
      Enum.find_value(content, "", fn block -> if is_map(block), do: Map.get(block, :text) || Map.get(block, "text") end)

  defp failure_code(:persistence_failed), do: "persistence_failed"
  defp failure_code(:authorization_denied), do: "authorization_denied"
  defp failure_code(:observation_failed), do: "observation_failed"
  defp failure_code(reason) when reason in [:unsupported, :timeout, :provider_failure], do: "provider_failure"
  defp failure_code(_), do: "delivery_failed"
  defp options(opts), do: Jido.Messaging.EventOptions.normalize(opts)
end
