defmodule Jido.Messaging.Demo.Topology do
  @moduledoc """
  YAML-backed bootstrap helpers for demo runtime topology.

  This module keeps demo setup declarative by loading a topology file and
  applying bridge configs, rooms, bindings, and routing policies.
  """

  alias Jido.Chat.Room

  @type t :: map()
  @type summary :: %{
          bridge_configs: non_neg_integer(),
          rooms: non_neg_integer(),
          room_bindings: non_neg_integer(),
          routing_policies: non_neg_integer()
        }

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = topology} -> {:ok, topology}
        {:ok, other} -> {:error, {:invalid_topology, other}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:not_found, path}}
    end
  end

  @spec mode(t()) :: :echo | :bridge | :agent | nil
  def mode(topology) when is_map(topology) do
    topology
    |> get_value("mode")
    |> normalize_mode()
  end

  @spec bridge_value(t(), String.t()) :: term()
  def bridge_value(topology, key) when is_map(topology) and is_binary(key) do
    bridge = get_value(topology, "bridge", %{})
    get_value(bridge, key)
  end

  @spec adapter_module(t(), String.t()) :: module() | nil
  def adapter_module(topology, key) when is_map(topology) and is_binary(key) do
    topology
    |> bridge_value(key)
    |> normalize_module()
  end

  @spec apply(module(), t()) :: {:ok, summary()} | {:error, term()}
  def apply(instance_module, topology)
      when is_atom(instance_module) and is_map(topology) do
    bridge_configs = list_value(topology, "bridge_configs")
    rooms = list_value(topology, "rooms")
    room_bindings = list_value(topology, "room_bindings")
    routing_policies = list_value(topology, "routing_policies")

    with :ok <- apply_bridge_configs(instance_module, bridge_configs),
         :ok <- apply_rooms(instance_module, rooms),
         :ok <- apply_room_bindings(instance_module, room_bindings),
         :ok <- apply_routing_policies(instance_module, routing_policies) do
      {:ok,
       %{
         bridge_configs: length(bridge_configs),
         rooms: length(rooms),
         room_bindings: length(room_bindings),
         routing_policies: length(routing_policies)
       }}
    end
  end

  defp apply_bridge_configs(_instance_module, []), do: :ok

  defp apply_bridge_configs(instance_module, configs) do
    Enum.reduce_while(configs, :ok, fn config, :ok ->
      attrs =
        config
        |> normalize_map()
        |> normalize_bridge_adapter()

      case attrs do
        {:error, reason} ->
          {:halt, {:error, {:invalid_bridge_config, reason, config}}}

        normalized_attrs ->
          case Jido.Messaging.put_bridge_config(instance_module, normalized_attrs) do
            {:ok, _config} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:bridge_config_failed, reason, config}}}
          end
      end
    end)
  end

  defp apply_rooms(_instance_module, []), do: :ok

  defp apply_rooms(instance_module, rooms) do
    Enum.reduce_while(rooms, :ok, fn room_entry, :ok ->
      entry = normalize_map(room_entry)
      room_id = get_value(entry, :id)

      with room_id when is_binary(room_id) and room_id != "" <- room_id do
        case instance_module.get_room(room_id) do
          {:ok, _room} ->
            {:cont, :ok}

          {:error, :not_found} ->
            room_attrs = %{
              id: room_id,
              type: normalize_room_type(get_value(entry, :type, :group)),
              name: get_value(entry, :name),
              metadata: get_value(entry, :metadata, %{}),
              external_bindings: get_value(entry, :external_bindings, %{})
            }

            case instance_module.save_room(Room.new(room_attrs)) do
              {:ok, _room} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:room_create_failed, reason, room_entry}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:room_lookup_failed, reason, room_entry}}}
        end
      else
        _ -> {:halt, {:error, {:invalid_room, room_entry}}}
      end
    end)
  end

  defp apply_room_bindings(_instance_module, []), do: :ok

  defp apply_room_bindings(instance_module, bindings) do
    Enum.reduce_while(bindings, :ok, fn binding_entry, :ok ->
      entry = normalize_map(binding_entry)
      room_id = get_value(entry, :room_id) |> normalize_id()
      bridge_id = get_value(entry, :bridge_id) |> normalize_id()
      external_room_id = get_value(entry, :external_room_id) |> normalize_id()
      channel = entry |> get_value(:channel) |> normalize_channel()

      with room_id when is_binary(room_id) and room_id != "" <- room_id,
           bridge_id when is_binary(bridge_id) and bridge_id != "" <- bridge_id,
           external_room_id when is_binary(external_room_id) and external_room_id != "" <- external_room_id,
           channel when is_atom(channel) <- channel do
        attrs =
          entry
          |> Map.drop([:room_id, :channel, :bridge_id, :external_room_id])
          |> normalize_room_binding_attrs()

        case instance_module.get_room_by_external_binding(channel, bridge_id, external_room_id) do
          {:ok, _room} ->
            {:cont, :ok}

          {:error, :not_found} ->
            case instance_module.create_room_binding(
                   room_id,
                   channel,
                   bridge_id,
                   external_room_id,
                   attrs
                 ) do
              {:ok, _binding} ->
                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, {:room_binding_failed, reason, binding_entry}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:room_binding_lookup_failed, reason, binding_entry}}}
        end
      else
        _ -> {:halt, {:error, {:invalid_room_binding, binding_entry}}}
      end
    end)
  end

  defp apply_routing_policies(_instance_module, []), do: :ok

  defp apply_routing_policies(instance_module, policies) do
    Enum.reduce_while(policies, :ok, fn policy_entry, :ok ->
      entry = normalize_map(policy_entry)
      room_id = get_value(entry, :room_id) || get_value(entry, :id)

      with room_id when is_binary(room_id) and room_id != "" <- room_id do
        attrs = Map.put(entry, :room_id, room_id)

        case instance_module.put_routing_policy(room_id, attrs) do
          {:ok, _policy} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:routing_policy_failed, reason, policy_entry}}}
        end
      else
        _ -> {:halt, {:error, {:invalid_routing_policy, policy_entry}}}
      end
    end)
  end

  defp normalize_bridge_adapter(attrs) do
    module_name = get_value(attrs, :adapter_module)

    case normalize_module(module_name) do
      nil -> {:error, :invalid_adapter_module}
      adapter_module -> Map.put(attrs, :adapter_module, adapter_module)
    end
  end

  defp normalize_mode(:echo), do: :echo
  defp normalize_mode(:bridge), do: :bridge
  defp normalize_mode(:agent), do: :agent
  defp normalize_mode("echo"), do: :echo
  defp normalize_mode("bridge"), do: :bridge
  defp normalize_mode("agent"), do: :agent
  defp normalize_mode(_), do: nil

  defp normalize_room_type(:direct), do: :direct
  defp normalize_room_type(:group), do: :group
  defp normalize_room_type(:channel), do: :channel
  defp normalize_room_type(:thread), do: :thread
  defp normalize_room_type("direct"), do: :direct
  defp normalize_room_type("group"), do: :group
  defp normalize_room_type("channel"), do: :channel
  defp normalize_room_type("thread"), do: :thread
  defp normalize_room_type(_), do: :group

  defp normalize_channel(:telegram), do: :telegram
  defp normalize_channel(:discord), do: :discord

  defp normalize_channel(value) when is_binary(value) do
    case value do
      "telegram" -> :telegram
      "discord" -> :discord
      _ -> nil
    end
  end

  defp normalize_channel(_), do: nil

  defp normalize_module(module) when is_atom(module), do: module

  defp normalize_module(module_name) when is_binary(module_name) and module_name != "" do
    module_name
    |> String.split(".")
    |> Module.concat()
  end

  defp normalize_module(_), do: nil

  defp normalize_id(value) when is_binary(value) and value != "", do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_id(_), do: nil

  defp normalize_room_binding_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.update(:direction, :both, &normalize_direction/1)
    |> Map.update(:enabled, true, &normalize_boolean/1)
  end

  defp normalize_direction(:both), do: :both
  defp normalize_direction(:inbound), do: :inbound
  defp normalize_direction(:outbound), do: :outbound
  defp normalize_direction("both"), do: :both
  defp normalize_direction("inbound"), do: :inbound
  defp normalize_direction("outbound"), do: :outbound
  defp normalize_direction(_), do: :both

  defp normalize_boolean(true), do: true
  defp normalize_boolean(false), do: false
  defp normalize_boolean("true"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean("1"), do: true
  defp normalize_boolean("0"), do: false
  defp normalize_boolean(1), do: true
  defp normalize_boolean(0), do: false
  defp normalize_boolean(_), do: true

  defp list_value(map, key) when is_map(map) and is_binary(key) do
    case get_value(map, key, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp get_value(map, key, default \\ nil)

  defp get_value(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp get_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        atom_key = safe_key_to_atom(key)
        Map.put(acc, atom_key || key, value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp safe_key_to_atom("id"), do: :id
  defp safe_key_to_atom("room_id"), do: :room_id
  defp safe_key_to_atom("type"), do: :type
  defp safe_key_to_atom("name"), do: :name
  defp safe_key_to_atom("metadata"), do: :metadata
  defp safe_key_to_atom("external_bindings"), do: :external_bindings
  defp safe_key_to_atom("bridge_id"), do: :bridge_id
  defp safe_key_to_atom("channel"), do: :channel
  defp safe_key_to_atom("external_room_id"), do: :external_room_id
  defp safe_key_to_atom("direction"), do: :direction
  defp safe_key_to_atom("enabled"), do: :enabled
  defp safe_key_to_atom("delivery_mode"), do: :delivery_mode
  defp safe_key_to_atom("failover_policy"), do: :failover_policy
  defp safe_key_to_atom("dedupe_scope"), do: :dedupe_scope
  defp safe_key_to_atom("fallback_order"), do: :fallback_order
  defp safe_key_to_atom("credentials"), do: :credentials
  defp safe_key_to_atom("opts"), do: :opts
  defp safe_key_to_atom("capabilities"), do: :capabilities
  defp safe_key_to_atom("revision"), do: :revision
  defp safe_key_to_atom("adapter_module"), do: :adapter_module
  defp safe_key_to_atom(_), do: nil
end
