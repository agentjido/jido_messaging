defmodule Jido.Messaging.IdentityData do
  @moduledoc false

  @max_reference_bytes 512
  @max_metadata_bytes 65_536
  @max_list_items 256

  @sensitive_fragments [
    "access_token",
    "agent_spec",
    "credential_secret",
    "environment",
    "function",
    "handler",
    "key_material",
    "passphrase",
    "password",
    "private_key",
    "public_key",
    "raw_proof",
    "secret",
    "signature",
    "signed_payload",
    "token",
    "tool"
  ]

  @doc false
  @spec required!(term(), atom()) :: String.t()
  def required!(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{field} is required"
      normalized when byte_size(normalized) <= @max_reference_bytes -> normalized
      _normalized -> raise ArgumentError, "#{field} is too long"
    end
  end

  def required!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec optional!(term(), atom()) :: String.t() | nil
  def optional!(nil, _field), do: nil
  def optional!(value, field), do: required!(value, field)

  @doc false
  @spec string_list!(term(), atom(), keyword()) :: [String.t()]
  def string_list!(values, field, opts \\ [])

  def string_list!(values, field, opts)
      when is_list(values) and length(values) <= @max_list_items do
    result = values |> Enum.map(&required!(&1, field)) |> Enum.uniq() |> Enum.sort()

    if Keyword.get(opts, :non_empty, false) and result == [] do
      raise ArgumentError, "#{field} must not be empty"
    end

    result
  end

  def string_list!(_values, field, _opts),
    do: raise(ArgumentError, "#{field} must be a bounded list of strings")

  @doc false
  @spec metadata!(term()) :: map()
  def metadata!(metadata) when is_map(metadata) and not is_struct(metadata) do
    if :erlang.external_size(metadata) > @max_metadata_bytes do
      raise ArgumentError, "identity credential metadata is too large"
    end

    walk_map!(metadata)
    metadata
  end

  def metadata!(_metadata), do: raise(ArgumentError, "identity credential metadata must be a plain map")

  @doc false
  @spec reject_raw_identity_material!(map()) :: :ok
  def reject_raw_identity_material!(attrs) when is_map(attrs) do
    attrs
    |> Map.keys()
    |> Enum.each(fn key ->
      normalized = normalize_key!(key)

      if sensitive_key?(normalized) do
        raise ArgumentError, "identity credential cannot contain #{normalized}"
      end
    end)
  end

  @doc false
  @spec value(map(), atom(), term()) :: term()
  def value(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp walk_map!(map) do
    Enum.each(map, fn {key, value} ->
      normalized = normalize_key!(key)

      if sensitive_key?(normalized) do
        raise ArgumentError, "identity credential metadata cannot contain #{normalized}"
      end

      walk_value!(value)
    end)
  end

  defp walk_value!(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or is_atom(value),
       do: :ok

  defp walk_value!(%DateTime{}), do: :ok
  defp walk_value!(value) when is_map(value) and not is_struct(value), do: walk_map!(value)

  defp walk_value!(value) when is_list(value) and length(value) <= @max_list_items,
    do: Enum.each(value, &walk_value!/1)

  defp walk_value!(_value),
    do: raise(ArgumentError, "identity credential metadata must contain only bounded safe data")

  defp sensitive_key?(key), do: Enum.any?(@sensitive_fragments, &String.contains?(key, &1))

  defp normalize_key!(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key!(key) when is_binary(key), do: key |> String.trim() |> String.downcase()
  defp normalize_key!(_key), do: raise(ArgumentError, "identity credential keys must be strings or atoms")
end
