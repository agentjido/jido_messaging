defmodule Jido.Messaging.ActivityData do
  @moduledoc false

  @max_reference_bytes 512
  @max_label_bytes 512
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
  @spec strict_keys!(map(), [atom()]) :: :ok
  def strict_keys!(attrs, allowed) when is_map(attrs) and is_list(allowed) do
    allowed = allowed |> Enum.flat_map(&[&1, Atom.to_string(&1)]) |> MapSet.new()

    case Enum.reject(Map.keys(attrs), &MapSet.member?(allowed, &1)) do
      [] -> :ok
      _unknown -> raise ArgumentError, "activity projection contains unsupported or unsafe fields"
    end
  end

  @doc false
  @spec required_ref!(term(), atom()) :: String.t()
  def required_ref!(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{field} is required"
      normalized when byte_size(normalized) <= @max_reference_bytes -> normalized
      _normalized -> raise ArgumentError, "#{field} is too long"
    end
  end

  def required_ref!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @doc false
  @spec optional_ref!(term(), atom()) :: String.t() | nil
  def optional_ref!(nil, _field), do: nil
  def optional_ref!(value, field), do: required_ref!(value, field)

  @doc false
  @spec optional_label!(term()) :: String.t() | nil
  def optional_label!(nil), do: nil

  def optional_label!(value) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" -> nil
      not String.valid?(normalized) -> raise ArgumentError, "activity summary label must be valid UTF-8"
      byte_size(normalized) > @max_label_bytes -> raise ArgumentError, "activity summary label is too long"
      String.contains?(normalized, <<0>>) -> raise ArgumentError, "activity summary label contains invalid data"
      true -> normalized
    end
  end

  def optional_label!(_value), do: raise(ArgumentError, "activity summary label must be a string")

  @doc false
  @spec optional_code!(term()) :: String.t() | nil
  def optional_code!(nil), do: nil

  def optional_code!(value) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" ->
        nil

      byte_size(normalized) > @max_code_bytes ->
        raise ArgumentError, "activity summary code is too long"

      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/, normalized) ->
        raise ArgumentError, "activity summary code contains invalid characters"

      true ->
        normalized
    end
  end

  def optional_code!(_value), do: raise(ArgumentError, "activity summary code must be a string")

  @doc false
  @spec required_code!(term(), atom()) :: String.t()
  def required_code!(value, field) do
    case optional_code!(value) do
      nil -> raise ArgumentError, "#{field} is required"
      code -> code
    end
  end

  @doc false
  @spec positive_revision!(term()) :: pos_integer()
  def positive_revision!(revision) when is_integer(revision) and revision > 0, do: revision
  def positive_revision!(_revision), do: raise(ArgumentError, "source_revision must be a positive integer")
end
