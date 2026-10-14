defmodule Jido.Messaging.Agents.Assignment do
  @moduledoc false

  alias Jido.Messaging.{AgentRunner, AgentSupervisor, RoomServer, RoomSupervisor, Thread}
  import Jido.Messaging, only: [get_thread: 2, get_room: 2, list_threads: 2, save_thread_struct: 2]

  @doc false
  @spec register_agent(module(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register_agent(instance_module, room_id, agent_spec, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_map(agent_spec) and is_list(opts) do
    normalized_spec = normalize_agent_spec(agent_spec, opts)

    with {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, threads} <- assignment_threads(runtime_name(instance_module), room_id),
         {:ok, registered_spec} <- room_server_register_agent(room_server, normalized_spec),
         :ok <- restore_agent_assignments(instance_module, room_id, room_server, registered_spec, threads) do
      {:ok, registered_spec}
    end
  end

  @doc false
  @spec unregister_agent(module(), String.t(), String.t()) :: :ok | {:error, term()}
  def unregister_agent(instance_module, room_id, agent_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(agent_id) do
    runtime = runtime_name(instance_module)

    with {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, thread_ids} <- assigned_thread_ids_for_agent(runtime, room_server, room_id, agent_id) do
      thread_ids
      |> Enum.reduce_while(:ok, fn thread_id, :ok ->
        case unassign_thread(instance_module, room_id, thread_id) do
          {:ok, _thread} ->
            {:cont, :ok}

          {:error, :not_found} ->
            with :ok <- stop_thread_runner(instance_module, room_id, thread_id, agent_id),
                 :ok <- room_server_unassign_thread(room_server, thread_id),
                 do: {:cont, :ok},
                 else: ({:error, reason} -> {:halt, {:error, reason}})

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok -> room_server_unregister_agent(room_server, agent_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec list_agents(module(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_agents(instance_module, room_id)
      when is_atom(instance_module) and is_binary(room_id) do
    with {:ok, room_server} <- ensure_room_server(instance_module, room_id) do
      {:ok, RoomServer.list_agents(room_server)}
    end
  end

  @doc false
  @spec assign_thread(module(), String.t(), String.t(), String.t()) :: {:ok, Thread.t()} | {:error, term()}
  def assign_thread(instance_module, room_id, thread_id, agent_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(thread_id) and is_binary(agent_id) do
    runtime = runtime_name(instance_module)

    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id),
         {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, agent_spec} <- room_server_get_agent(room_server, agent_id) do
      previous_agent_id = room_server_thread_assignment(room_server, thread_id) || thread.assigned_agent_id

      previous_agent_spec =
        registered_agent_spec(instance_module, room_id, thread_id, room_server, previous_agent_id)

      case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
        pid when is_pid(pid) and previous_agent_id == agent_id ->
          updated_thread = maybe_touch_thread_assignment(thread, agent_id)

          with {:ok, persisted_thread} <- persist_thread_assignment(runtime, updated_thread),
               :ok <- room_server_assign_thread(room_server, thread_id, agent_id) do
            {:ok, persisted_thread}
          else
            {:error, reason} ->
              _ = persist_thread_assignment(runtime, thread)
              {:error, reason}
          end

        _ ->
          updated_thread = %{thread | assigned_agent_id: agent_id, updated_at: DateTime.utc_now()}

          case stop_thread_runner(instance_module, room_id, thread_id, previous_agent_id) do
            :ok ->
              case assign_thread_state(
                     runtime,
                     room_server,
                     instance_module,
                     room_id,
                     thread_id,
                     agent_id,
                     agent_spec,
                     updated_thread
                   ) do
                {:ok, persisted_thread} ->
                  {:ok, persisted_thread}

                {:error, reason} ->
                  case rollback_thread_assignment(
                         instance_module,
                         runtime,
                         room_server,
                         thread,
                         previous_agent_spec
                       ) do
                    :ok -> {:error, reason}
                    {:error, rollback_reason} -> {:error, {:assignment_failed, reason, rollback_reason}}
                  end
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc false
  @spec unassign_thread(module(), String.t(), String.t()) :: {:ok, Thread.t()} | {:error, term()}
  def unassign_thread(instance_module, room_id, thread_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(thread_id) do
    runtime = runtime_name(instance_module)

    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id),
         {:ok, room_server} <- ensure_room_server(instance_module, room_id) do
      assigned_agent_id = room_server_thread_assignment(room_server, thread_id) || thread.assigned_agent_id

      assigned_agent_spec =
        registered_agent_spec(instance_module, room_id, thread_id, room_server, assigned_agent_id)

      case stop_thread_runner(instance_module, room_id, thread_id, assigned_agent_id) do
        :ok ->
          updated_thread = %{thread | assigned_agent_id: nil, updated_at: DateTime.utc_now()}

          case unassign_thread_state(runtime, room_server, updated_thread) do
            {:ok, persisted_thread} ->
              {:ok, persisted_thread}

            {:error, reason} ->
              case rollback_thread_assignment(
                     instance_module,
                     runtime,
                     room_server,
                     thread,
                     assigned_agent_spec
                   ) do
                :ok -> {:error, reason}
                {:error, rollback_reason} -> {:error, {:unassignment_failed, reason, rollback_reason}}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec thread_assignment(module(), String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def thread_assignment(instance_module, room_id, thread_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(thread_id) do
    runtime = runtime_name(instance_module)

    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id) do
      {:ok, resolve_thread_assignment(instance_module, room_id, thread_id, thread)}
    end
  end

  @doc false
  @spec restore_agent_runners(module()) :: :ok | {:error, term()}
  def restore_agent_runners(instance_module) when is_atom(instance_module) do
    runtime = runtime_name(instance_module)
    room_supervisor = Module.concat(instance_module, :RoomSupervisor)

    if is_nil(Process.whereis(runtime)) or is_nil(Process.whereis(room_supervisor)) do
      {:error, :runtime_unavailable}
    else
      RoomSupervisor.list_rooms(instance_module)
      |> Enum.reduce_while(:ok, fn {room_id, room_server}, :ok ->
        with {:ok, agents} <- room_server_list_agents(room_server),
             {:ok, threads} <- assignment_threads(runtime, room_id),
             :ok <- restore_registered_threads(instance_module, room_id, room_server, agents, threads) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  @spec restore_room_server_state(module(), String.t(), pid()) :: :ok
  def restore_room_server_state(instance_module, room_id, room_server)
      when is_atom(instance_module) and is_binary(room_id) and is_pid(room_server) do
    instance_module
    |> AgentSupervisor.list_agents(room_id)
    |> Enum.each(fn {{thread_id, agent_id}, pid} ->
      case runner_agent_spec(pid, agent_id) do
        {:ok, agent_spec} ->
          _ = room_server_register_agent(room_server, agent_spec)
          _ = room_server_assign_thread(room_server, thread_id, agent_id)
          :ok

        {:error, _reason} ->
          :ok
      end
    end)

    :ok
  end

  defp map_get(map, atom_key) when is_map(map) and is_atom(atom_key),
    do: Map.get(map, atom_key, Map.get(map, Atom.to_string(atom_key)))

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value) and value != "", do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_id(_), do: nil

  defp normalize_agent_spec(agent_spec, opts) when is_map(agent_spec) and is_list(opts) do
    agent_id =
      map_get(agent_spec, :agent_id) ||
        map_get(agent_spec, :id) ||
        raise ArgumentError, "agent_spec requires :agent_id"

    name = map_get(agent_spec, :name) || agent_id

    mention_handles =
      agent_spec
      |> map_get(:mention_handles)
      |> case do
        handles when is_list(handles) -> handles
        _ -> [agent_id, name]
      end
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    agent_spec
    |> Map.put(:agent_id, normalize_id(agent_id))
    |> Map.put(:name, normalize_id(name) || to_string(name))
    |> Map.put(:mention_handles, mention_handles)
    |> Map.put_new(:trigger, Keyword.get(opts, :trigger, :thread))
  end

  defp restore_registered_threads(instance_module, room_id, room_server, agents, threads) do
    Enum.reduce_while(agents, :ok, fn agent_spec, :ok ->
      case restore_agent_assignments(instance_module, room_id, room_server, agent_spec, threads) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp restore_agent_assignments(instance_module, room_id, room_server, agent_spec, threads) do
    agent_id = agent_spec.agent_id

    Enum.reduce_while(threads, :ok, fn
      %Thread{id: thread_id, assigned_agent_id: ^agent_id}, :ok ->
        with {:ok, assignment} <- room_server_thread_assignment_result(room_server, thread_id) do
          if assignment in [nil, agent_id] do
            with :ok <- room_server_assign_thread(room_server, thread_id, agent_id),
                 {:ok, _pid} <- ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec),
                 do: {:cont, :ok},
                 else: ({:error, _} = error -> {:halt, error})
          else
            {:cont, :ok}
          end
        else
          {:error, _} = error -> {:halt, error}
        end

      _thread, :ok ->
        {:cont, :ok}
    end)
  end

  defp assigned_thread_ids_for_agent(runtime, room_server, room_id, agent_id) do
    with {:ok, assignments} <- room_server_list_thread_assignments(room_server),
         {:ok, threads} <- assignment_threads(runtime, room_id) do
      in_memory = for {thread_id, ^agent_id} <- assignments, do: thread_id
      persisted = for %Thread{id: thread_id, assigned_agent_id: ^agent_id} <- threads, do: thread_id
      {:ok, Enum.uniq(in_memory ++ persisted)}
    end
  end

  defp assignment_threads(runtime, room_id) do
    case list_threads(runtime, room_id) do
      {:ok, threads} when is_list(threads) ->
        if Enum.all?(threads, fn
             %Thread{id: id, room_id: ^room_id, assigned_agent_id: agent} ->
               is_binary(id) and id != "" and (is_nil(agent) or is_binary(agent))

             _ ->
               false
           end) and length(threads) == length(Enum.uniq_by(threads, & &1.id)),
           do: {:ok, threads},
           else: {:error, :persistence_failed}

      {:error, _} = error ->
        error

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
    start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec)
  end

  defp persist_thread_assignment(runtime, %Thread{} = thread) do
    case save_thread_struct(runtime, thread) do
      {:ok, %Thread{id: id, room_id: room_id} = saved} when id == thread.id and room_id == thread.room_id ->
        {:ok, saved}

      {:error, _} = error ->
        error

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp resolve_thread_assignment(instance_module, room_id, thread_id, %Thread{} = thread) do
    case ensure_room_server(instance_module, room_id) do
      {:ok, room_server} ->
        case room_server_thread_assignment_result(room_server, thread_id) do
          {:ok, assignment} -> assignment || thread.assigned_agent_id
          {:error, _reason} -> thread.assigned_agent_id
        end

      {:error, _reason} ->
        thread.assigned_agent_id
    end
  end

  defp assign_thread_state(
         runtime,
         room_server,
         instance_module,
         room_id,
         thread_id,
         agent_id,
         agent_spec,
         updated_thread
       ) do
    with {:ok, persisted_thread} <- persist_thread_assignment(runtime, updated_thread),
         :ok <- room_server_assign_thread(room_server, thread_id, agent_id),
         {:ok, _pid} <- start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
      {:ok, persisted_thread}
    end
  end

  defp unassign_thread_state(runtime, room_server, updated_thread) do
    with {:ok, persisted_thread} <- persist_thread_assignment(runtime, updated_thread),
         :ok <- room_server_unassign_thread(room_server, updated_thread.id) do
      {:ok, persisted_thread}
    end
  end

  defp rollback_thread_assignment(
         instance_module,
         runtime,
         room_server,
         %Thread{} = original_thread,
         previous_agent_spec
       ) do
    with {:ok, _thread} <- persist_thread_assignment(runtime, original_thread),
         :ok <- restore_room_server_assignment(room_server, original_thread, previous_agent_spec),
         :ok <- restore_thread_runner(instance_module, original_thread, previous_agent_spec) do
      :ok
    end
  end

  defp restore_room_server_assignment(room_server, %Thread{assigned_agent_id: agent_id} = thread, agent_spec)
       when is_binary(agent_id) and is_map(agent_spec) do
    with {:ok, _registered_agent} <- room_server_register_agent(room_server, agent_spec),
         :ok <- restore_room_server_assignment(room_server, %{thread | assigned_agent_id: agent_id}, nil) do
      :ok
    end
  end

  defp restore_room_server_assignment(room_server, %Thread{id: thread_id, assigned_agent_id: agent_id}, _agent_spec)
       when is_binary(agent_id) do
    room_server_assign_thread(room_server, thread_id, agent_id)
  end

  defp restore_room_server_assignment(room_server, %Thread{id: thread_id}, _agent_spec) do
    room_server_unassign_thread(room_server, thread_id)
  end

  defp restore_thread_runner(_instance_module, %Thread{assigned_agent_id: nil}, _previous_agent_spec), do: :ok

  defp restore_thread_runner(
         instance_module,
         %Thread{room_id: room_id, id: thread_id, assigned_agent_id: agent_id},
         agent_spec
       )
       when is_binary(agent_id) and is_map(agent_spec) do
    case start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_thread_runner(_instance_module, %Thread{assigned_agent_id: _agent_id}, _previous_agent_spec), do: :ok

  defp registered_agent_spec(_instance_module, _room_id, _thread_id, _room_server, nil), do: nil

  defp registered_agent_spec(instance_module, room_id, thread_id, room_server, agent_id) when is_binary(agent_id) do
    case room_server_get_agent(room_server, agent_id) do
      {:ok, agent_spec} ->
        agent_spec

      {:error, _reason} ->
        case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
          pid when is_pid(pid) ->
            case runner_agent_spec(pid, agent_id) do
              {:ok, agent_spec} -> agent_spec
              {:error, _reason} -> nil
            end

          nil ->
            nil
        end
    end
  end

  defp start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
    case AgentSupervisor.start_agent(instance_module, room_id, thread_id, agent_id, agent_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_agent_failed, reason}}
    end
  end

  defp stop_thread_runner(_instance_module, _room_id, _thread_id, nil), do: :ok

  defp stop_thread_runner(instance_module, room_id, thread_id, agent_id) when is_binary(agent_id) do
    case AgentSupervisor.stop_agent(instance_module, room_id, thread_id, agent_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:stop_agent_failed, reason}}
    end
  end

  defp room_server_get_agent(room_server, agent_id) do
    try do
      RoomServer.get_agent(room_server, agent_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_assign_thread(room_server, thread_id, agent_id) do
    try do
      RoomServer.assign_thread(room_server, thread_id, agent_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_unassign_thread(room_server, thread_id) do
    try do
      RoomServer.unassign_thread(room_server, thread_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_thread_assignment(room_server, thread_id) do
    case room_server_thread_assignment_result(room_server, thread_id) do
      {:ok, assignment} -> assignment
      {:error, _reason} -> nil
    end
  end

  defp room_server_thread_assignment_result(room_server, thread_id) do
    try do
      {:ok, RoomServer.thread_assignment(room_server, thread_id)}
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_list_thread_assignments(room_server) do
    try do
      {:ok, RoomServer.list_thread_assignments(room_server)}
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_list_agents(room_server) do
    try do
      {:ok, RoomServer.list_agents(room_server)}
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_register_agent(room_server, agent_spec) when is_map(agent_spec) do
    try do
      RoomServer.register_agent(room_server, agent_spec)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_unregister_agent(room_server, agent_id) do
    try do
      RoomServer.unregister_agent(room_server, agent_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp runner_agent_spec(pid, fallback_agent_id) when is_pid(pid) and is_binary(fallback_agent_id) do
    try do
      case AgentRunner.get_state(pid) do
        %AgentRunner{agent_id: agent_id, agent_config: agent_config} when is_map(agent_config) ->
          {:ok,
           agent_config
           |> Map.put(:agent_id, agent_id || fallback_agent_id)
           |> Map.put_new(:name, fallback_agent_id)}

        _other ->
          {:error, :runner_state_unavailable}
      end
    catch
      :exit, reason -> {:error, {:runner_unavailable, reason}}
    end
  end

  defp maybe_touch_thread_assignment(%Thread{assigned_agent_id: agent_id} = thread, agent_id), do: thread

  defp maybe_touch_thread_assignment(%Thread{} = thread, agent_id) do
    %{thread | assigned_agent_id: agent_id, updated_at: DateTime.utc_now()}
  end

  defp ensure_thread_room(%Thread{room_id: room_id}, room_id), do: :ok
  defp ensure_thread_room(%Thread{}, _room_id), do: {:error, :thread_room_mismatch}

  defp ensure_room_server(instance_module, room_id) do
    runtime = runtime_name(instance_module)

    with {:ok, room} <- get_room(runtime, room_id) do
      RoomSupervisor.get_or_start_room(instance_module, room)
    end
  end

  defp runtime_name(instance_module), do: Module.concat(instance_module, :Runtime)
end
