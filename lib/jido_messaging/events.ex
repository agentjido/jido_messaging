defmodule Jido.Messaging.Events do
  @moduledoc """
  Constructors for `Jido.Messaging` domain events as `Jido.Signal` CloudEvents.

  These events describe committed local messaging state. `jido_chat` still owns
  adapter-facing envelopes and payloads; this module carries the normalized
  runtime facts that small chat apps, bridges, agents, and UIs can subscribe to.
  """

  alias Jido.Chat.Wire
  alias Jido.Messaging.Message

  @type event_type ::
          :message_added
          | :message_received
          | :message_sent
          | :message_failed
          | :room_created
          | :participant_joined
          | :participant_left
          | :presence_changed
          | :typing
          | :reaction_added
          | :reaction_removed
          | :message_delivered
          | :message_read
          | :thread_created
          | :thread_reply_added
          | atom()

  @spec message_added(module(), Message.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def message_added(instance_module, %Message{} = message, opts \\ []) do
    opts = normalize_opts(opts)

    data =
      message
      |> message_data(opts)
      |> Map.put("event", "message_added")

    new(:message_added, instance_module, message.room_id, data, opts)
  end

  @spec message_received(module() | nil, Message.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def message_received(instance_module, %Message{} = message, opts \\ []) do
    opts = normalize_opts(opts)

    data =
      message
      |> message_data(opts)
      |> Map.put("event", "message_received")

    new(:message_received, instance_module, message.room_id, data, opts)
  end

  @spec message_sent(module() | nil, Message.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def message_sent(instance_module, %Message{} = message, opts \\ []) do
    opts = normalize_opts(opts)

    data =
      message
      |> message_data(opts)
      |> Map.put("event", "message_sent")

    new(:message_sent, instance_module, message.room_id, data, opts)
  end

  @spec message_failed(module() | nil, String.t(), term(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def message_failed(instance_module, room_id, reason, opts \\ []) do
    opts = normalize_opts(opts)

    data =
      %{
        "event" => "message_failed",
        "room_id" => room_id,
        "message_id" => opts[:message_id],
        "reason" => inspect(reason)
      }
      |> merge_platform(opts)

    new(:message_failed, instance_module, room_id, data, opts)
  end

  @spec reaction_added(module(), Message.t(), String.t(), String.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def reaction_added(instance_module, %Message{} = message, participant_id, reaction, opts \\ []) do
    reaction_event(:reaction_added, instance_module, message, participant_id, reaction, opts)
  end

  @spec reaction_removed(module(), Message.t(), String.t(), String.t(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def reaction_removed(instance_module, %Message{} = message, participant_id, reaction, opts \\ []) do
    reaction_event(:reaction_removed, instance_module, message, participant_id, reaction, opts)
  end

  @spec room_event(module(), event_type(), String.t(), map(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def room_event(instance_module, event_type, room_id, data, opts \\ [])
      when is_atom(event_type) and is_map(data) do
    opts = normalize_opts(opts)

    data =
      data
      |> Wire.to_plain()
      |> Map.put_new("event", Atom.to_string(event_type))
      |> Map.put_new("room_id", room_id)
      |> merge_platform(opts)

    new(event_type, instance_module, room_id, data, opts)
  end

  @spec new(String.t() | event_type(), module() | nil, String.t() | nil, map(), keyword() | map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def new(type_or_event, instance_module, subject, data, opts \\ []) when is_map(data) do
    opts = normalize_opts(opts)
    type = type_for(type_or_event)

    signal_opts =
      %{
        source: build_source(instance_module, opts[:bridge_id] || opts[:instance_id]),
        subject: subject
      }
      |> maybe_put(:correlationid, correlation_id(type_or_event, data, opts))
      |> maybe_put(:causation_id, opts[:causation_id])
      |> maybe_put(:dataschema, opts[:dataschema])

    Jido.Signal.new(type, data, signal_opts)
  end

  @spec type_for(String.t() | event_type()) :: String.t()
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
  def telemetry_event_for(type) when is_binary(type) do
    type
    |> event_type_from_signal_type()
    |> telemetry_event_for()
  end

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

  @spec message_data(Message.t(), keyword() | map()) :: map()
  def message_data(%Message{} = message, opts \\ []) do
    opts = normalize_opts(opts)
    text = text_from_content(message.content)

    %{
      "message" => Wire.to_plain(message),
      "message_id" => message.id,
      "room_id" => message.room_id,
      "thread_id" => message.thread_id,
      "reply_to_id" => message.reply_to_id,
      "sender_id" => message.sender_id,
      "role" => message.role,
      "status" => message.status,
      "text" => text,
      "content" => message.content,
      "reactions" => message.reactions || %{},
      "target" => target_data(message, opts),
      "payload" => payload_data(message, text, opts)
    }
    |> merge_platform(opts)
    |> Wire.to_plain()
  end

  defp reaction_event(event_type, instance_module, message, participant_id, reaction, opts) do
    opts = normalize_opts(opts)

    data =
      message
      |> message_data(opts)
      |> Map.merge(%{
        "event" => Atom.to_string(event_type),
        "participant_id" => participant_id,
        "reaction" => reaction
      })

    new(event_type, instance_module, message.room_id, data, opts)
  end

  defp target_data(message, opts) do
    external_id =
      opts[:external_room_id] || message.delivery_external_room_id ||
        get_in(message.metadata || %{}, [:external_room_id]) || message.room_id

    %{
      "kind" => target_kind(message, opts),
      "external_id" => metadata_value(external_id),
      "thread_id" => metadata_value(message.external_thread_id || message.thread_id),
      "reply_to_id" => metadata_value(message.external_reply_to_id || message.reply_to_id),
      "instance_id" => metadata_value(opts[:bridge_id] || opts[:instance_id]),
      "channel_type" => metadata_value(opts[:channel_type] || channel_name(opts[:channel]))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp payload_data(message, text, opts) do
    %{
      "kind" => payload_kind(message, opts),
      "text" => text,
      "metadata" =>
        %{
          "message_id" => message.id,
          "room_id" => message.room_id,
          "source" => (message.metadata || %{})[:source]
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp merge_platform(data, opts) do
    platform =
      %{
        "channel" => channel_name(opts[:channel]),
        "channel_type" => metadata_value(opts[:channel_type]),
        "bridge_id" => metadata_value(opts[:bridge_id]),
        "external_room_id" => metadata_value(opts[:external_room_id]),
        "external_message_id" => metadata_value(opts[:external_message_id]),
        "external_thread_id" => metadata_value(opts[:external_thread_id]),
        "delivery_external_room_id" => metadata_value(opts[:delivery_external_room_id]),
        "adapter_event_type" => metadata_value(opts[:adapter_event_type])
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if platform == %{}, do: data, else: Map.put(data, "platform", platform)
  end

  defp target_kind(%Message{thread_id: thread_id}, _opts) when is_binary(thread_id), do: "thread"
  defp target_kind(_message, opts), do: opts |> Keyword.get(:target_kind, opts[:chat_type] || "room") |> to_string()

  defp payload_kind(_message, opts), do: metadata_value(opts[:payload_kind]) || "text"

  defp metadata_value(nil), do: nil
  defp metadata_value(value) when is_binary(value), do: value
  defp metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_value(value), do: to_string(value)

  defp text_from_content([%{text: text} | _]) when is_binary(text), do: text
  defp text_from_content([%{"text" => text} | _]) when is_binary(text), do: text
  defp text_from_content([%{type: "text", text: text} | _]) when is_binary(text), do: text
  defp text_from_content([%{"type" => "text", "text" => text} | _]) when is_binary(text), do: text
  defp text_from_content(_content), do: nil

  defp event_type_from_signal_type("jido.messaging.message.received"), do: :message_received
  defp event_type_from_signal_type("jido.messaging.message.sent"), do: :message_sent
  defp event_type_from_signal_type("jido.messaging.message.failed"), do: :message_failed
  defp event_type_from_signal_type("jido.messaging.room.message_added"), do: :message_added
  defp event_type_from_signal_type("jido.messaging.room.created"), do: :room_created
  defp event_type_from_signal_type("jido.messaging.message.reaction_added"), do: :reaction_added
  defp event_type_from_signal_type("jido.messaging.message.reaction_removed"), do: :reaction_removed
  defp event_type_from_signal_type("jido.messaging.thread.reply_added"), do: :thread_reply_added

  defp event_type_from_signal_type(type) do
    type
    |> String.split(".")
    |> List.last()
    |> String.to_atom()
  end

  defp build_source(nil, nil), do: "jido_messaging/local"
  defp build_source(nil, instance_id), do: "jido_messaging/local/#{instance_id}"

  defp build_source(instance_module, instance_id) do
    base = "jido_messaging/#{inspect(instance_module)}"
    if instance_id, do: "#{base}/#{instance_id}", else: base
  end

  defp correlation_id(_type, _data, opts) do
    case opts[:correlation_id] || opts[:message_id] do
      nil -> nil
      value -> %{id: value}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Map.put(opts, key, value)

  defp channel_name(nil), do: nil
  defp channel_name(module) when is_atom(module), do: to_string(module)
  defp channel_name(other), do: inspect(other)

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
end
