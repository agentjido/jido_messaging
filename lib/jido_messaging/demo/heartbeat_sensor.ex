defmodule JidoMessaging.Demo.HeartbeatSensor do
  @moduledoc """
  A Jido Sensor that emits periodic heartbeat messages to a chat room.

  This sensor demonstrates Jido's sensor capability for scheduling periodic
  events. It fires every minute (60 seconds) and sends a thematic message
  from Agent Jido to the chat room.

  ## Usage

  Start the sensor with the messaging room context:

      {:ok, _pid} = Jido.Sensor.Runtime.start_link(
        sensor: JidoMessaging.Demo.HeartbeatSensor,
        config: %{
          interval: 60_000,
          room_id: "demo:lobby",
          instance_module: JidoMessaging.Demo.Messaging
        }
      )

  ## How It Works

  1. On init, the sensor schedules an immediate tick (`{:schedule, 0}`)
  2. On each `:tick` event, it sends a message to the chat room
  3. After sending, it schedules the next tick (`{:schedule, interval}`)

  The sensor uses the messaging system directly rather than emitting signals,
  since it's a standalone demo component that writes to the chat room.
  """

  use Jido.Sensor,
    name: "heartbeat_sensor",
    description: "Sends periodic heartbeat messages to a chat room",
    schema:
      Zoi.object(
        %{
          interval: Zoi.integer() |> Zoi.default(60_000),
          room_id: Zoi.string(),
          instance_module: Zoi.any()
        },
        coerce: true
      )

  require Logger

  @impl Jido.Sensor
  def init(config, _context) do
    state = %{
      interval: config.interval,
      room_id: config.room_id,
      instance_module: config.instance_module,
      tick_count: 0
    }

    Logger.info("[HeartbeatSensor] Initialized - interval: #{config.interval}ms, room: #{config.room_id}")

    # Schedule first tick immediately
    {:ok, state, [{:schedule, 0}]}
  end

  @impl Jido.Sensor
  def handle_event(:tick, state) do
    send_heartbeat_message(state)
    new_state = %{state | tick_count: state.tick_count + 1}

    # Schedule next tick
    {:ok, new_state, [{:schedule, state.interval}]}
  end

  defp send_heartbeat_message(state) do
    alias JidoMessaging.Content.Text
    alias JidoMessaging.RoomServer

    now = DateTime.utc_now()
    formatted_time = Calendar.strftime(now, "%H:%M:%S UTC")

    messages = [
      "🛰️ Orbital status check: All systems nominal. Station time: #{formatted_time}",
      "📡 Transmission from low Earth orbit. Current time: #{formatted_time}. BEAM processes: stable.",
      "🌍 Greetings from orbit! The view is spectacular at #{formatted_time}.",
      "⚡ Heartbeat from Agent Jido. Time sync: #{formatted_time}. Awaiting input.",
      "🔭 Scanning frequencies... Agent Jido online at #{formatted_time}. Ready to assist."
    ]

    text = Enum.random(messages)

    message_attrs = %{
      room_id: state.room_id,
      sender_id: "chat_agent",
      role: :assistant,
      content: [%Text{text: text}],
      status: :sent,
      metadata: %{
        channel: :agent,
        username: "ChatAgent",
        display_name: "Agent Jido",
        agent_name: "ChatAgent",
        heartbeat: true,
        tick_count: state.tick_count + 1
      }
    }

    case state.instance_module.save_message(message_attrs) do
      {:ok, message} ->
        case RoomServer.whereis(state.instance_module, state.room_id) do
          nil ->
            Logger.debug("[HeartbeatSensor] Room server not running, message saved but not broadcast")

          pid ->
            RoomServer.add_message(pid, message)
        end

        Logger.info("[HeartbeatSensor] Sent heartbeat ##{state.tick_count + 1}: #{text}")

      {:error, reason} ->
        Logger.warning("[HeartbeatSensor] Failed to save heartbeat message: #{inspect(reason)}")
    end
  end
end
