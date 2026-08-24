defmodule Jido.Messaging.ContinuityData do
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
  @spec optional_code!(term(), atom()) :: String.t() | nil
  def optional_code!(nil, _field), do: nil

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

  def optional_code!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec required_code!(term(), atom()) :: String.t()
  def required_code!(value, field) do
    case optional_code!(value, field) do
      nil -> raise ArgumentError, "#{field} is required"
      code -> code
    end
  end

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
  @spec positive_revision!(term()) :: pos_integer()
  def positive_revision!(revision) when is_integer(revision) and revision > 0, do: revision
  def positive_revision!(_revision), do: raise(ArgumentError, "source_revision must be a positive integer")

  @doc false
  @spec source_time!(term(), DateTime.t()) :: DateTime.t()
  def source_time!(%DateTime{} = value, %DateTime{} = now) do
    normalized = normalize_datetime(value)

    if DateTime.compare(normalized, DateTime.add(now, 300, :second)) == :gt do
      raise ArgumentError, "source_updated_at is too far in the future"
    end

    normalized
  end

  def source_time!(_value, _now), do: raise(ArgumentError, "source_updated_at must be a DateTime")

  @doc false
  @spec optional_time!(term(), atom()) :: DateTime.t() | nil
  def optional_time!(nil, _field), do: nil
  def optional_time!(%DateTime{} = value, _field), do: normalize_datetime(value)
  def optional_time!(_value, field), do: raise(ArgumentError, "#{field} must be a DateTime")

  @doc false
  @spec jidoka_ref!(term()) :: map()
  def jidoka_ref!(reference) when is_map(reference) and not is_struct(reference) do
    strict_keys!(reference, [:system, :id], "jidoka_agent_ref")

    if value(reference, :system) not in [:jidoka, "jidoka"] do
      raise ArgumentError, "jidoka_agent_ref system must be jidoka"
    end

    %{"system" => "jidoka", "id" => reference |> value(:id) |> required_ref!(:jidoka_agent_id)}
  end

  def jidoka_ref!(_reference), do: raise(ArgumentError, "jidoka_agent_ref must be a map")

  defp normalize_datetime(value) do
    value
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  defp logical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp logical_key(key), do: key
end
