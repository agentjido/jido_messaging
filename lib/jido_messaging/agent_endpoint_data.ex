defmodule Jido.Messaging.AgentEndpointData do
  @moduledoc false

  @max_reference_bytes 512

  @forbidden_keys MapSet.new([
                    "access_token",
                    "agent_spec",
                    "api_key",
                    "controls",
                    "credential",
                    "credentials",
                    "env",
                    "environment",
                    "function",
                    "functions",
                    "handler",
                    "instructions",
                    "memory",
                    "model",
                    "model_config",
                    "private_key",
                    "prompt",
                    "prompts",
                    "secret",
                    "secrets",
                    "session",
                    "snapshot",
                    "spec",
                    "token",
                    "tool",
                    "tools",
                    "turn"
                  ])

  @doc false
  @spec normalize_required!(term(), atom()) :: String.t()
  def normalize_required!(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{field} is required"
      normalized when byte_size(normalized) <= @max_reference_bytes -> normalized
      _normalized -> raise ArgumentError, "#{field} is too long"
    end
  end

  def normalize_required!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec normalize_optional!(term(), atom()) :: String.t() | nil
  def normalize_optional!(nil, _field), do: nil
  def normalize_optional!(value, field), do: normalize_required!(value, field)

  @doc false
  @spec normalize_jidoka_ref!(term()) :: map()
  def normalize_jidoka_ref!(reference) when is_map(reference) do
    allowed_keys = [:system, :id, "system", "id"]
    extra_keys = Map.keys(reference) -- allowed_keys
    system = value(reference, :system)
    external_id = value(reference, :id)

    if extra_keys == [] and system in [:jidoka, "jidoka"] do
      %{
        "system" => "jidoka",
        "id" => normalize_required!(external_id, :jidoka_agent_id)
      }
    else
      raise ArgumentError, "jidoka_agent_ref permits only jidoka system and string id fields"
    end
  end

  def normalize_jidoka_ref!(_reference), do: raise(ArgumentError, "jidoka_agent_ref must be an opaque map")

  @doc false
  @spec validate_metadata!(term()) :: map()
  def validate_metadata!(metadata) when is_map(metadata) and not is_struct(metadata) do
    walk_map!(metadata)
    metadata
  end

  def validate_metadata!(_metadata), do: raise(ArgumentError, "agent endpoint metadata must be a plain map")

  defp walk_map!(map) do
    Enum.each(map, fn {key, value} ->
      normalized_key = normalize_key!(key)

      if forbidden_key?(normalized_key) do
        raise ArgumentError, "agent endpoint metadata cannot contain #{normalized_key}"
      end

      walk_value!(value)
    end)
  end

  defp walk_value!(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or is_atom(value),
       do: :ok

  defp walk_value!(%DateTime{}), do: :ok
  defp walk_value!(value) when is_map(value) and not is_struct(value), do: walk_map!(value)
  defp walk_value!(value) when is_list(value), do: Enum.each(value, &walk_value!/1)

  defp walk_value!(_value) do
    raise ArgumentError, "agent endpoint metadata must contain only safe data values"
  end

  defp normalize_key!(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key!(key) when is_binary(key), do: key |> String.trim() |> String.downcase()
  defp normalize_key!(_key), do: raise(ArgumentError, "agent endpoint metadata keys must be strings or atoms")

  defp forbidden_key?(key) do
    MapSet.member?(@forbidden_keys, key) or
      String.contains?(key, "token") or
      String.contains?(key, "secret") or
      String.contains?(key, "credential") or
      String.contains?(key, "private_key") or
      String.contains?(key, "api_key")
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
