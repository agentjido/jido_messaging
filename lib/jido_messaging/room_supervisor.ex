defmodule Jido.Messaging.RoomSupervisor do
  @moduledoc """
  DynamicSupervisor for spawning and managing RoomServer processes.

  Each Jido.Messaging instance has its own RoomSupervisor that manages
  room servers on-demand.
  """
  use DynamicSupervisor

  alias Jido.Chat.Room
  alias Jido.Messaging.RoomServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a room server for the given room.

  Returns `{:ok, pid}` if started successfully, or `{:error, {:already_started, pid}}`
  if the room server is already running.

  Options:
  - `:message_limit` - Max messages to keep in memory (default: 100)
  - `:timeout_ms` - Inactivity timeout (default: 5 minutes)
  """
  def start_room(instance_module, %Room{} = room, opts \\ []) do
    supervisor = Module.concat(instance_module, RoomSupervisor)

    child_spec = {
      RoomServer,
      [room: room, instance_module: instance_module] ++ opts
    }

    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Get an existing room server or start a new one.

  Returns `{:ok, pid}` in both cases.
  """
  def get_or_start_room(instance_module, %Room{} = room, opts \\ []) do
    case RoomServer.whereis(instance_module, room.id) do
      nil ->
        case start_room(instance_module, room, opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Stop a room server.

  Returns `:ok` if stopped, or `{:error, :not_found}` if not running.
  """
  def stop_room(instance_module, room_id) do
    case RoomServer.whereis(instance_module, room_id) do
      nil ->
        {:error, :not_found}

      pid ->
        supervisor = Module.concat(instance_module, RoomSupervisor)
        DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @doc "List all running room servers for this instance"
  def list_rooms(instance_module) do
    supervisor = Module.concat(instance_module, RoomSupervisor)
    registry = Module.concat(instance_module, Registry.Rooms)

    DynamicSupervisor.which_children(supervisor)
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(registry, pid) do
        [room_id] -> {room_id, pid}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Count running room servers"
  def count_rooms(instance_module) do
    supervisor = Module.concat(instance_module, RoomSupervisor)
    DynamicSupervisor.count_children(supervisor).active
  end
end
