defmodule Jido.Messaging.Routing.BridgeRoom do
  @moduledoc false

  alias Jido.Chat.Room
  alias Jido.Messaging.{BridgeRoomSpec, TopologyValidator}

  import Jido.Messaging,
    only: [
      put_bridge_config: 2,
      get_room: 2,
      save_room: 2,
      get_room_by_external_binding: 4,
      create_room_binding: 6,
      get_bridge_config: 2,
      put_routing_policy: 3
    ]

  @doc false
  @spec create_bridge_room(module(), map()) :: {:ok, Room.t()} | {:error, term()}
  def create_bridge_room(instance_module, attrs)
      when is_atom(instance_module) and is_map(attrs) do
    spec = BridgeRoomSpec.new(attrs)
    room_id = spec.room_id || "bridge:" <> Jido.Chat.ID.generate!()
    runtime = runtime_name(instance_module)

    with :ok <- TopologyValidator.validate_bridge_room_spec(instance_module, spec),
         :ok <- ensure_bridge_configs(instance_module, spec.bridge_configs),
         {:ok, room} <- ensure_room(runtime, room_id, spec),
         {:ok, _bindings} <- ensure_bindings(runtime, instance_module, room_id, spec.bindings),
         {:ok, _policy} <- ensure_routing_policy(instance_module, room_id, spec.routing_policy) do
      {:ok, room}
    end
  end

  defp ensure_bridge_configs(_instance_module, []), do: :ok

  defp ensure_bridge_configs(instance_module, bridge_configs) when is_list(bridge_configs) do
    Enum.reduce_while(bridge_configs, :ok, fn config, :ok ->
      attrs = normalize_bridge_config_attrs(config)

      case put_bridge_config(instance_module, attrs) do
        {:ok, _bridge} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:bridge_config_failed, reason, config}}}
      end
    end)
  end

  defp ensure_room(runtime, room_id, %BridgeRoomSpec{} = spec) do
    case get_room(runtime, room_id) do
      {:ok, room} ->
        {:ok, room}

      {:error, :not_found} ->
        save_room(
          runtime,
          Room.new(%{
            id: room_id,
            type: spec.room_type,
            name: spec.room_name,
            metadata: spec.room_metadata
          })
        )

      {:error, reason} ->
        {:error, {:room_lookup_failed, reason}}
    end
  end

  defp ensure_bindings(_runtime, _instance_module, _room_id, []), do: {:ok, []}

  defp ensure_bindings(runtime, instance_module, room_id, bindings) when is_list(bindings) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, acc} ->
      with {:ok, normalized} <- normalize_binding(binding),
           {:ok, _bridge} <- ensure_binding_bridge_enabled(instance_module, normalized.bridge_id),
           {:ok, result} <- ensure_binding(runtime, room_id, normalized) do
        {:cont, {:ok, [result | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_binding(runtime, room_id, normalized) do
    case get_room_by_external_binding(
           runtime,
           normalized.channel,
           normalized.bridge_id,
           normalized.external_room_id
         ) do
      {:ok, %Room{id: ^room_id}} ->
        {:ok, :existing}

      {:ok, %Room{id: existing_room_id}} ->
        {:error,
         {:binding_conflict,
          %{
            room_id: room_id,
            existing_room_id: existing_room_id,
            channel: normalized.channel,
            bridge_id: normalized.bridge_id,
            external_room_id: normalized.external_room_id
          }}}

      {:error, :not_found} ->
        create_room_binding(
          runtime,
          room_id,
          normalized.channel,
          normalized.bridge_id,
          normalized.external_room_id,
          normalized.attrs
        )

      {:error, reason} ->
        {:error, {:binding_lookup_failed, reason}}
    end
  end

  defp ensure_binding_bridge_enabled(instance_module, bridge_id) when is_binary(bridge_id) do
    case get_bridge_config(instance_module, bridge_id) do
      {:ok, %{enabled: true} = config} -> {:ok, config}
      {:ok, %{enabled: false}} -> {:error, {:bridge_disabled, bridge_id}}
      {:error, :not_found} -> {:error, {:bridge_not_found, bridge_id}}
    end
  end

  defp ensure_routing_policy(_instance_module, _room_id, policy) when policy in [%{}, nil], do: {:ok, nil}

  defp ensure_routing_policy(instance_module, room_id, policy) when is_map(policy) do
    attrs = Map.put(policy, :room_id, room_id)

    case put_routing_policy(instance_module, room_id, attrs) do
      {:ok, routing_policy} -> {:ok, routing_policy}
      {:error, reason} -> {:error, {:routing_policy_failed, reason}}
    end
  end

  defp normalize_bridge_config_attrs(config) when is_map(config) do
    normalized =
      Enum.reduce(config, %{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
        {key, value}, acc when is_binary(key) -> put_bridge_config_string_key(acc, key, value)
        {_key, _value}, acc -> acc
      end)

    normalized
    |> Map.put_new(:enabled, true)
    |> Map.put_new(:opts, %{})
    |> Map.put_new(:credentials, %{})
  end

  defp put_bridge_config_string_key(acc, key, value) when is_map(acc) and is_binary(key) do
    case bridge_config_key_to_atom(key) do
      nil -> Map.put(acc, key, value)
      atom_key -> Map.put(acc, atom_key, value)
    end
  end

  defp bridge_config_key_to_atom("id"), do: :id
  defp bridge_config_key_to_atom("adapter_module"), do: :adapter_module
  defp bridge_config_key_to_atom("adapter"), do: :adapter_module
  defp bridge_config_key_to_atom("credentials"), do: :credentials
  defp bridge_config_key_to_atom("opts"), do: :opts
  defp bridge_config_key_to_atom("enabled"), do: :enabled
  defp bridge_config_key_to_atom("capabilities"), do: :capabilities
  defp bridge_config_key_to_atom("delivery_policy"), do: :delivery_policy
  defp bridge_config_key_to_atom("revision"), do: :revision
  defp bridge_config_key_to_atom("inserted_at"), do: :inserted_at
  defp bridge_config_key_to_atom("updated_at"), do: :updated_at
  defp bridge_config_key_to_atom(_), do: nil

  defp normalize_binding(binding) when is_map(binding) do
    channel = map_get(binding, :channel) |> normalize_channel()
    bridge_id = map_get(binding, :bridge_id) |> normalize_id()
    external_room_id = map_get(binding, :external_room_id) |> normalize_id()
    direction = map_get(binding, :direction) |> normalize_direction()
    enabled = map_get(binding, :enabled) |> normalize_bool()

    with true <- channel in [:telegram, :discord],
         true <- is_binary(bridge_id),
         true <- is_binary(external_room_id) do
      attrs =
        binding
        |> drop_keys([
          :channel,
          "channel",
          :bridge_id,
          "bridge_id",
          :external_room_id,
          "external_room_id",
          :direction,
          "direction",
          :enabled,
          "enabled"
        ])
        |> put_attr(:direction, direction)
        |> put_attr(:enabled, enabled)

      {:ok,
       %{
         channel: channel,
         bridge_id: bridge_id,
         external_room_id: external_room_id,
         attrs: attrs
       }}
    else
      _ -> {:error, {:invalid_binding, binding}}
    end
  end

  defp map_get(map, atom_key) when is_map(map) and is_atom(atom_key),
    do: Map.get(map, atom_key, Map.get(map, Atom.to_string(atom_key)))

  defp drop_keys(map, keys), do: Enum.reduce(keys, map, &Map.delete(&2, &1))

  defp put_attr(attrs, key, value) when is_map(attrs), do: Map.put(attrs, key, value)

  defp normalize_channel(:telegram), do: :telegram
  defp normalize_channel(:discord), do: :discord
  defp normalize_channel("telegram"), do: :telegram
  defp normalize_channel("discord"), do: :discord
  defp normalize_channel(_), do: nil

  defp normalize_direction(:inbound), do: :inbound
  defp normalize_direction(:outbound), do: :outbound
  defp normalize_direction("inbound"), do: :inbound
  defp normalize_direction("outbound"), do: :outbound
  defp normalize_direction(_), do: :both

  defp normalize_bool(true), do: true
  defp normalize_bool(false), do: false
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool("1"), do: true
  defp normalize_bool("0"), do: false
  defp normalize_bool(1), do: true
  defp normalize_bool(0), do: false
  defp normalize_bool(_), do: true

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value) and value != "", do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_id(_), do: nil

  defp runtime_name(instance_module), do: Module.concat(instance_module, :Runtime)
end
