defmodule Jido.Messaging.AuthorizationData do
  @moduledoc false

  @max_id_bytes 512
  @max_list_items 256
  @max_safe_map_bytes 65_536

  @forbidden_key_fragments [
    "api_key",
    "agent_spec",
    "control",
    "credential",
    "env",
    "environment",
    "function",
    "handler",
    "instruction",
    "memory",
    "model",
    "private_key",
    "prompt",
    "secret",
    "session",
    "snapshot",
    "token",
    "tool",
    "runtime_limit"
  ]

  @doc false
  @spec required_id!(term(), atom()) :: String.t()
  def required_id!(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{field} is required"
      normalized when byte_size(normalized) <= @max_id_bytes -> normalized
      _normalized -> raise ArgumentError, "#{field} is too long"
    end
  end

  def required_id!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec optional_id!(term(), atom()) :: String.t() | nil
  def optional_id!(nil, _field), do: nil
  def optional_id!(value, field), do: required_id!(value, field)

  @doc false
  @spec id_list!(term(), atom()) :: [String.t()]
  def id_list!(values, field) when is_list(values) and length(values) <= @max_list_items do
    values
    |> Enum.map(&required_id!(&1, field))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def id_list!(_values, field), do: raise(ArgumentError, "#{field} must be a bounded list of strings")

  @doc false
  @spec safe_map!(term(), atom()) :: map()
  def safe_map!(value, field) when is_map(value) and not is_struct(value) do
    walk_map!(value, field)

    if :erlang.external_size(value) > @max_safe_map_bytes do
      raise ArgumentError, "#{field} is too large"
    end

    value
  end

  def safe_map!(_value, field), do: raise(ArgumentError, "#{field} must be a plain map")

  @doc false
  @spec constraints!(term()) :: map()
  def constraints!(constraints) when is_map(constraints) and not is_struct(constraints) do
    normalized =
      Map.new(constraints, fn {key, value} ->
        case normalize_key!(key) do
          "max_results" -> {"max_results", positive_integer!(value, :max_results)}
          "requires_membership" -> {"requires_membership", boolean!(value, :requires_membership)}
          unknown -> raise ArgumentError, "unsupported grant constraint #{unknown}"
        end
      end)

    Map.put_new(normalized, "requires_membership", true)
  end

  def constraints!(_constraints), do: raise(ArgumentError, "constraints must be a plain map")

  @doc false
  @spec value(map(), atom(), term()) :: term()
  def value(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp walk_map!(map, field) do
    Enum.each(map, fn {key, value} ->
      normalized_key = normalize_key!(key)

      if Enum.any?(@forbidden_key_fragments, &String.contains?(normalized_key, &1)) do
        raise ArgumentError, "#{field} cannot contain #{normalized_key}"
      end

      walk_value!(value, field)
    end)
  end

  defp walk_value!(value, _field)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or is_atom(value),
       do: :ok

  defp walk_value!(%DateTime{}, _field), do: :ok
  defp walk_value!(value, field) when is_map(value) and not is_struct(value), do: walk_map!(value, field)

  defp walk_value!(value, field) when is_list(value) and length(value) <= @max_list_items,
    do: Enum.each(value, &walk_value!(&1, field))

  defp walk_value!(_value, field),
    do: raise(ArgumentError, "#{field} must contain only bounded safe data values")

  defp normalize_key!(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key!(key) when is_binary(key), do: key |> String.trim() |> String.downcase()
  defp normalize_key!(_key), do: raise(ArgumentError, "map keys must be strings or atoms")

  defp positive_integer!(value, _field) when is_integer(value) and value > 0, do: value
  defp positive_integer!(_value, field), do: raise(ArgumentError, "#{field} must be a positive integer")
  defp boolean!(value, _field) when is_boolean(value), do: value
  defp boolean!(_value, field), do: raise(ArgumentError, "#{field} must be a boolean")
end
