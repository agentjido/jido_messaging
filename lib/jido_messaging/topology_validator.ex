defmodule Jido.Messaging.TopologyValidator do
  @moduledoc """
  Validation helpers for bridge-room topology payloads.
  """

  alias Jido.Messaging.{BridgeRoomSpec, ConfigStore}

  @type validation_error :: %{code: atom(), detail: map()}

  @spec validate_bridge_room_spec(module(), BridgeRoomSpec.t()) ::
          :ok | {:error, {:invalid_topology, [validation_error()]}}
  def validate_bridge_room_spec(instance_module, %BridgeRoomSpec{} = spec) when is_atom(instance_module) do
    existing_bridge_ids =
      ConfigStore.list_bridge_configs(instance_module)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    declared_bridge_ids =
      spec.bridge_configs
      |> Enum.map(&map_get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    all_bridge_ids = MapSet.union(existing_bridge_ids, MapSet.new(declared_bridge_ids))

    errors =
      []
      |> validate_bridge_configs(spec.bridge_configs)
      |> validate_binding_uniqueness(spec.bindings)
      |> validate_binding_bridge_refs(spec.bindings, all_bridge_ids)
      |> validate_routing_policy(spec.routing_policy, all_bridge_ids)

    case errors do
      [] -> :ok
      _ -> {:error, {:invalid_topology, Enum.reverse(errors)}}
    end
  end

  defp validate_bridge_configs(errors, bridge_configs) do
    bridge_ids =
      bridge_configs
      |> Enum.map(&map_get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    duplicate_bridge_ids =
      bridge_ids
      |> Enum.group_by(& &1)
      |> Enum.filter(fn {_bridge_id, ids} -> length(ids) > 1 end)
      |> Enum.map(&elem(&1, 0))

    errors =
      Enum.reduce(duplicate_bridge_ids, errors, fn bridge_id, acc ->
        [
          %{code: :duplicate_bridge_id, detail: %{bridge_id: bridge_id}}
          | acc
        ]
      end)

    Enum.reduce(bridge_configs, errors, fn config, acc ->
      case map_get(config, :adapter_module) do
        module when is_atom(module) ->
          acc

        other ->
          [
            %{code: :invalid_bridge_adapter_module, detail: %{bridge_id: map_get(config, :id), adapter_module: other}}
            | acc
          ]
      end
    end)
  end

  defp validate_binding_uniqueness(errors, bindings) do
    keys =
      bindings
      |> Enum.map(fn binding ->
        {
          map_get(binding, :channel),
          normalize_id(map_get(binding, :bridge_id)),
          normalize_id(map_get(binding, :external_room_id))
        }
      end)

    duplicates =
      keys
      |> Enum.group_by(& &1)
      |> Enum.filter(fn {_key, values} -> length(values) > 1 end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(duplicates, errors, fn {channel, bridge_id, external_room_id}, acc ->
      [
        %{
          code: :duplicate_binding,
          detail: %{channel: channel, bridge_id: bridge_id, external_room_id: external_room_id}
        }
        | acc
      ]
    end)
  end

  defp validate_binding_bridge_refs(errors, bindings, known_bridge_ids) do
    Enum.reduce(bindings, errors, fn binding, acc ->
      bridge_id = normalize_id(map_get(binding, :bridge_id))

      if is_binary(bridge_id) and MapSet.member?(known_bridge_ids, bridge_id) do
        acc
      else
        [%{code: :unknown_binding_bridge_id, detail: %{bridge_id: bridge_id, binding: binding}} | acc]
      end
    end)
  end

  defp validate_routing_policy(errors, routing_policy, known_bridge_ids) when is_map(routing_policy) do
    fallback_order = map_get(routing_policy, :fallback_order)

    case fallback_order do
      nil ->
        errors

      order when is_list(order) ->
        Enum.reduce(order, errors, fn bridge_id, acc ->
          normalized = normalize_id(bridge_id)

          if is_binary(normalized) and MapSet.member?(known_bridge_ids, normalized) do
            acc
          else
            [%{code: :unknown_routing_bridge_id, detail: %{bridge_id: normalized}} | acc]
          end
        end)

      other ->
        [%{code: :invalid_routing_fallback_order, detail: %{fallback_order: other}} | errors]
    end
  end

  defp validate_routing_policy(errors, _routing_policy, _known_bridge_ids), do: errors

  defp map_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)
end
