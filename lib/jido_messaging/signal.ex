defmodule Jido.Messaging.Signal do
  @moduledoc "One typed emission path for Messaging facts and telemetry."
  alias Jido.Messaging.{Dispatch, Events, Message}

  @doc "Returns the standard private telemetry keys."
  @spec metadata_keys() :: [atom()]
  def metadata_keys, do: [:instance_module, :room_id, :bridge_id, :timestamp]

  @doc "Emits a fact after an inbound message is committed."
  @spec emit_received(Message.t(), map()) :: :ok
  def emit_received(message, context) do
    emit_built(
      context[:instance_module],
      Events.message_received(context[:instance_module], message, context_options(context)),
      :message_received,
      context |> Map.put(:message, message) |> Map.put_new(:participant_id, message.sender_id)
    )
  end

  @doc "Emits a fact after outbound delivery is committed."
  @spec emit_sent(Message.t(), map()) :: :ok
  def emit_sent(message, context) do
    emit_built(
      context[:instance_module],
      Events.message_sent(context[:instance_module], message, context_options(context)),
      :message_sent,
      context |> Map.put(:message, message) |> Map.put_new(:participant_id, message.sender_id)
    )
  end

  @doc "Emits a typed delivery failure without a private error value."
  @spec emit_failed(String.t(), term(), map()) :: :ok
  def emit_failed(room, reason, context) do
    emit_built(
      context[:instance_module],
      Events.message_failed(context[:instance_module], room, reason, context_options(context)),
      :message_failed,
      Map.put(context, :reason, reason)
    )
  end

  @doc "Emits one registered agent lifecycle fact."
  @spec emit_agent(atom(), module(), String.t(), String.t(), map()) :: :ok
  def emit_agent(event, instance, room, agent, data \\ %{}) do
    data = data |> Map.put(:agent_id, agent) |> Map.put(:room_id, room)
    data = if event == :failed, do: Map.put(data, :code, "agent_failure"), else: data

    emit_built(
      instance,
      Events.new("jido.messaging.agent.#{event}", instance, room, data, context_options(data)),
      "jido.messaging.agent.#{event}",
      data
    )
  end

  @doc "Emits one registered instance lifecycle fact."
  @spec emit_instance(atom(), module(), String.t(), map()) :: :ok
  def emit_instance(event, instance, id, data \\ %{}) do
    data = Map.put(data, :instance_id, id)
    data = if event == :error, do: Map.put(data, :code, "instance_failure"), else: data

    emit_built(
      instance,
      Events.new("jido.messaging.instance.#{event}", instance, nil, data),
      "jido.messaging.instance.#{event}",
      data
    )
  end

  @doc "Emits one registered room fact from private runtime state."
  @spec emit(atom(), module(), String.t(), map()) :: :ok
  def emit(event, instance, room, data) do
    emit_built(instance, Events.room_event(instance, event, room, data, context_options(data)), event, data)
  end

  defp emit_built(instance, {:ok, signal}, event, data) do
    _ =
      Dispatch.emit(instance, signal,
        telemetry_event: Events.telemetry_event_for(event),
        telemetry_metadata:
          Map.merge(data, %{
            instance_module: instance,
            room_id: signal.data["room_id"],
            bridge_id: data[:bridge_id],
            signal_id: signal.id,
            causation_id: Jido.Signal.Context.get(signal, "causationid"),
            code: signal.data["code"]
          }),
        telemetry_measurements: %{timestamp: DateTime.utc_now()}
      )

    :ok
  end

  defp emit_built(_instance, {:error, _}, _event, _data), do: :ok

  defp context_options(context) do
    parent = context[:parent_signal] || get_in(context, [:context, :parent_signal])

    [
      bridge_id: context[:bridge_id],
      external_room_id: context[:external_room_id],
      parent_signal: parent,
      message_id: context[:message_id]
    ]
  end
end
