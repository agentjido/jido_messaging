defmodule Jido.Messaging.Demo.HeartbeatSensor do
  @moduledoc """
  Sends periodic demo messages to a Messaging room.

  Start this process with `config: %{interval: 60_000, room_id: room_id,
  instance_module: messaging_module}`. The first tick occurs after one
  millisecond. `initial_delay` can set a different first delay.
  """

  use GenServer

  require Logger

  @schema Zoi.object(%{
            interval: Zoi.integer() |> Zoi.min(1) |> Zoi.default(60_000),
            room_id: Zoi.string(),
            instance_module: Zoi.atom()
          })

  @doc "Starts the demo heartbeat process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, config} <- Zoi.parse(@schema, Keyword.get(opts, :config)),
         delay when is_integer(delay) and delay >= 0 <- Keyword.get(opts, :initial_delay, 1) do
      GenServer.start_link(__MODULE__, {config, delay})
    else
      {:error, errors} -> {:error, {:invalid_config, errors}}
      _ -> {:error, :invalid_initial_delay}
    end
  end

  @impl true
  def init({config, delay}) do
    Process.send_after(self(), :tick, delay)
    {:ok, Map.put(config, :tick_count, 0)}
  end

  @impl true
  def handle_info(:tick, state) do
    send_heartbeat_message(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, %{state | tick_count: state.tick_count + 1}}
  end

  defp send_heartbeat_message(state) do
    alias Jido.Chat.Content.Text
    alias Jido.Messaging.RoomServer

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
