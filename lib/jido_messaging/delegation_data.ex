defmodule Jido.Messaging.DelegationData do
  @moduledoc false

  @max_reference_bytes 512
  @max_code_bytes 128

  @doc false
  @spec value(map(), atom(), term()) :: term()
  def value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  @doc false
  @spec strict_keys!(map(), [atom()], String.t()) :: :ok
  def strict_keys!(attrs, allowed, subject) when is_map(attrs) and is_list(allowed) do
    allowed = allowed |> Enum.flat_map(&[&1, Atom.to_string(&1)]) |> MapSet.new()
    keys = Map.keys(attrs)
    logical_keys = Enum.map(keys, &logical_key/1)

    cond do
      Enum.any?(keys, &(not MapSet.member?(allowed, &1))) ->
        raise ArgumentError, "#{subject} contains unsupported or unsafe fields"

      length(logical_keys) != length(Enum.uniq(logical_keys)) ->
        raise ArgumentError, "#{subject} contains duplicate fields"

      true ->
        :ok
    end
  end

  @doc false
  @spec required_ref!(term(), atom()) :: String.t()
  def required_ref!(value, field) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" -> raise ArgumentError, "#{field} is required"
      not String.valid?(normalized) -> raise ArgumentError, "#{field} must be valid UTF-8"
      byte_size(normalized) > @max_reference_bytes -> raise ArgumentError, "#{field} is too long"
      Regex.match?(~r/[\x00-\x1F\x7F]/, normalized) -> raise ArgumentError, "#{field} contains invalid data"
      true -> normalized
    end
  end

  def required_ref!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec optional_ref!(term(), atom()) :: String.t() | nil
  def optional_ref!(nil, _field), do: nil
  def optional_ref!(value, field), do: required_ref!(value, field)

  @doc false
  @spec required_code!(term(), atom()) :: String.t()
  def required_code!(value, field) do
    case optional_code!(value, field) do
      nil -> raise ArgumentError, "#{field} is required"
      code -> code
    end
  end

  @doc false
  @spec optional_code!(term(), atom()) :: String.t() | nil
  def optional_code!(nil, _field), do: nil

  def optional_code!(value, field) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> optional_code!(field)

  def optional_code!(value, field) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        nil

      byte_size(normalized) > @max_code_bytes ->
        raise ArgumentError, "#{field} is too long"

      not Regex.match?(~r/\A[a-z0-9][a-z0-9._:-]*\z/, normalized) ->
        raise ArgumentError, "#{field} contains invalid characters"

      true ->
        normalized
    end
  end

  def optional_code!(_value, field), do: raise(ArgumentError, "#{field} must be a string or atom")

  @doc false
  @spec enum!(term(), [atom()], atom()) :: atom()
  def enum!(value, allowed, field) when is_atom(value) do
    if value in allowed, do: value, else: raise(ArgumentError, "invalid #{field}")
  end

  def enum!(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> raise ArgumentError, "invalid #{field}"
      result -> result
    end
  end

  def enum!(_value, _allowed, field), do: raise(ArgumentError, "invalid #{field}")

  @doc false
  @spec optional_non_negative!(term(), atom()) :: non_neg_integer() | nil
  def optional_non_negative!(nil, _field), do: nil

  def optional_non_negative!(value, _field) when is_integer(value) and value >= 0,
    do: value

  def optional_non_negative!(_value, field),
    do: raise(ArgumentError, "#{field} must be a non-negative integer")

  @doc false
  @spec required_non_negative!(term(), atom()) :: non_neg_integer()
  def required_non_negative!(value, field) do
    case optional_non_negative!(value, field) do
      nil -> raise ArgumentError, "#{field} is required"
      result -> result
    end
  end

  @doc false
  @spec ref_list!(term(), atom(), keyword()) :: [String.t()]
  def ref_list!(values, field, opts \\ [])

  def ref_list!(values, field, opts) when is_list(values) do
    minimum = Keyword.get(opts, :minimum, 0)
    maximum = Keyword.get(opts, :maximum, 50)
    normalized = Enum.map(values, &required_ref!(&1, field))

    cond do
      length(normalized) < minimum -> raise ArgumentError, "#{field} has too few values"
      length(normalized) > maximum -> raise ArgumentError, "#{field} has too many values"
      length(normalized) != length(Enum.uniq(normalized)) -> raise ArgumentError, "#{field} has duplicate values"
      true -> normalized
    end
  end

  def ref_list!(_values, field, _opts), do: raise(ArgumentError, "#{field} must be a list")

  @doc false
  @spec jidoka_ref!(term(), atom()) :: map()
  def jidoka_ref!(reference, field) when is_map(reference) and not is_struct(reference) do
    strict_keys!(reference, [:system, :id], Atom.to_string(field))

    if value(reference, :system) not in [:jidoka, "jidoka"] do
      raise ArgumentError, "#{field} system must be jidoka"
    end

    %{"system" => "jidoka", "id" => reference |> value(:id) |> required_ref!(field)}
  end

  def jidoka_ref!(_reference, field), do: raise(ArgumentError, "#{field} must be a map")

  @doc false
  @spec stable_id(String.t(), term()) :: String.t()
  def stable_id(prefix, identity) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(identity))
      |> Base.url_encode64(padding: false)

    "#{prefix}_#{digest}"
  end

  defp logical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp logical_key(key), do: key
end
