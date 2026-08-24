defmodule Jido.Messaging.AgentDirectoryData do
  @moduledoc false

  @max_reference_bytes 512
  @max_name_bytes 256
  @max_description_bytes 1_024
  @max_code_bytes 128
  @max_capabilities 32
  @max_fresh_seconds 86_400

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
    normalize_bounded_string!(value, field, @max_reference_bytes, false)
  end

  def required_ref!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec optional_text!(term(), atom(), pos_integer()) :: String.t() | nil
  def optional_text!(nil, _field, _max_bytes), do: nil

  def optional_text!(value, field, max_bytes) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalize_bounded_string!(normalized, field, max_bytes, true)
    end
  end

  def optional_text!(_value, field, _max_bytes), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec name!(term()) :: String.t()
  def name!(value) when is_binary(value) do
    normalize_bounded_string!(value, :name, @max_name_bytes, true)
  end

  def name!(_value), do: raise(ArgumentError, "name must be a string")

  @doc false
  @spec description!(term()) :: String.t() | nil
  def description!(value), do: optional_text!(value, :description, @max_description_bytes)

  @doc false
  @spec code!(term(), atom()) :: String.t()
  def code!(value, field) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        raise ArgumentError, "#{field} is required"

      byte_size(normalized) > @max_code_bytes ->
        raise ArgumentError, "#{field} is too long"

      not Regex.match?(~r/\A[a-z0-9][a-z0-9._:-]*\z/, normalized) ->
        raise ArgumentError, "#{field} contains invalid characters"

      true ->
        normalized
    end
  end

  def code!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec capabilities!(term()) :: [String.t()]
  def capabilities!(values) when is_list(values) and length(values) <= @max_capabilities do
    values
    |> Enum.map(&code!(&1, :capability))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def capabilities!(_values), do: raise(ArgumentError, "capabilities must be a bounded list of safe codes")

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
  @spec fresh_seconds!(term()) :: pos_integer()
  def fresh_seconds!(value) when is_integer(value) and value > 0 and value <= @max_fresh_seconds, do: value

  def fresh_seconds!(_value),
    do: raise(ArgumentError, "fresh_for_seconds must be between 1 and #{@max_fresh_seconds}")

  @doc false
  @spec jidoka_ref!(term()) :: map()
  def jidoka_ref!(reference) when is_map(reference) and not is_struct(reference) do
    strict_keys!(reference, [:system, :id], "jidoka_agent_ref")
    system = value(reference, :system)

    if system not in [:jidoka, "jidoka"] do
      raise ArgumentError, "jidoka_agent_ref system must be jidoka"
    end

    %{"system" => "jidoka", "id" => reference |> value(:id) |> required_ref!(:jidoka_agent_id)}
  end

  def jidoka_ref!(_reference), do: raise(ArgumentError, "jidoka_agent_ref must be a map")

  defp normalize_bounded_string!(value, field, max_bytes, allow_spaces?) do
    normalized = String.trim(value)

    cond do
      normalized == "" ->
        raise ArgumentError, "#{field} is required"

      not String.valid?(normalized) ->
        raise ArgumentError, "#{field} must be valid UTF-8"

      byte_size(normalized) > max_bytes ->
        raise ArgumentError, "#{field} is too long"

      Regex.match?(~r/[\x00-\x1F\x7F]/, normalized) ->
        raise ArgumentError, "#{field} contains invalid data"

      not allow_spaces? and String.match?(normalized, ~r/\s/u) ->
        raise ArgumentError, "#{field} cannot contain whitespace"

      true ->
        normalized
    end
  end

  defp normalize_datetime(value) do
    value
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  defp logical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp logical_key(key), do: key
end
