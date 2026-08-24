defmodule Jido.Messaging.TrustEvidenceData do
  @moduledoc false

  @max_reference_bytes 512
  @max_code_bytes 128
  @max_capabilities 32
  @max_evidence_lifetime_seconds 31_622_400

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
      String.match?(normalized, ~r/\s/u) -> raise ArgumentError, "#{field} cannot contain whitespace"
      true -> normalized
    end
  end

  def required_ref!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec optional_ref!(term(), atom()) :: String.t() | nil
  def optional_ref!(nil, _field), do: nil
  def optional_ref!(value, field), do: required_ref!(value, field)

  @doc false
  @spec code!(term(), atom()) :: String.t()
  def code!(value, field) when is_atom(value) and not is_nil(value), do: value |> Atom.to_string() |> code!(field)

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

  def code!(_value, field), do: raise(ArgumentError, "#{field} must be a string or atom")

  @doc false
  @spec code_list!(term(), atom()) :: [String.t()]
  def code_list!(values, field) when is_list(values) and values != [] and length(values) <= @max_capabilities do
    values
    |> Enum.map(&code!(&1, field))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def code_list!(_values, field),
    do: raise(ArgumentError, "#{field} must be a non-empty bounded list of safe codes")

  @doc false
  @spec ref_list!(term(), atom()) :: [String.t()]
  def ref_list!(values, field) when is_list(values) and values != [] and length(values) <= 32 do
    normalized = Enum.map(values, &required_ref!(&1, field))

    if length(normalized) == length(Enum.uniq(normalized)) do
      normalized
    else
      raise ArgumentError, "#{field} contains duplicate values"
    end
  end

  def ref_list!(_values, field),
    do: raise(ArgumentError, "#{field} must be a non-empty bounded list")

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
  def positive_revision!(value)
      when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807,
      do: value

  def positive_revision!(_value), do: raise(ArgumentError, "source revision must be a positive integer")

  @doc false
  @spec jidoka_ref!(term()) :: map()
  def jidoka_ref!(reference) when is_map(reference) and not is_struct(reference) do
    strict_keys!(reference, [:system, :id], "Jidoka agent reference")

    if value(reference, :system) not in [:jidoka, "jidoka"] do
      raise ArgumentError, "agent reference system must be jidoka"
    end

    %{
      "system" => "jidoka",
      "id" => reference |> value(:id) |> required_ref!(:jidoka_agent_id)
    }
  end

  def jidoka_ref!(_reference), do: raise(ArgumentError, "Jidoka agent reference must be a plain map")

  @doc false
  @spec observed_at!(term(), DateTime.t()) :: DateTime.t()
  def observed_at!(%DateTime{} = value, %DateTime{} = now) do
    value = normalize_datetime(value)

    if DateTime.compare(value, DateTime.add(now, 300, :second)) == :gt do
      raise ArgumentError, "observed_at is too far in the future"
    end

    value
  end

  def observed_at!(_value, _now), do: raise(ArgumentError, "observed_at must be a DateTime")

  @doc false
  @spec expiry!(term(), DateTime.t()) :: DateTime.t()
  def expiry!(%DateTime{} = value, %DateTime{} = observed_at) do
    value = normalize_datetime(value)
    lifetime = DateTime.diff(value, observed_at, :second)

    cond do
      DateTime.compare(value, observed_at) != :gt ->
        raise ArgumentError, "evidence expiry must be after observed_at"

      lifetime > @max_evidence_lifetime_seconds ->
        raise ArgumentError, "evidence lifetime cannot exceed 366 days"

      true ->
        value
    end
  end

  def expiry!(_value, _observed_at), do: raise(ArgumentError, "expires_at must be a DateTime")

  @doc false
  @spec stable_id(String.t(), term()) :: String.t()
  def stable_id(prefix, identity) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(identity))
      |> Base.url_encode64(padding: false)

    "#{prefix}_#{digest}"
  end

  defp normalize_datetime(value) do
    value
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  defp logical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp logical_key(key), do: key
end
