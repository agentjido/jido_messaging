defmodule Jido.Messaging.IngressSubscription do
  @moduledoc """
  Normalized provider ingress subscription state for a bridge.

  Provider-specific options and response payloads stay in adapter code. This
  struct gives runtime/control-plane callers a small common envelope.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              bridge_id: Zoi.string(),
              adapter_name: Zoi.atom(),
              status: Zoi.atom() |> Zoi.default(:active),
              external_id: Zoi.string() |> Zoi.nullish(),
              subscription_id: Zoi.string() |> Zoi.nullish(),
              target_url: Zoi.string() |> Zoi.nullish(),
              expires_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              raw: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc "Builds a normalized ingress subscription from adapter/runtime attrs."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    bridge_id = Map.fetch!(attrs, :bridge_id)
    adapter_name = normalize_adapter_name(Map.fetch!(attrs, :adapter_name))
    subscription_id = normalize_optional_string(subscription_id(attrs))
    external_id = normalize_optional_string(Map.get(attrs, :external_id) || subscription_id)

    struct!(__MODULE__, %{
      bridge_id: to_string(bridge_id),
      adapter_name: adapter_name,
      status: normalize_status(Map.get(attrs, :status, :active)),
      external_id: external_id,
      subscription_id: subscription_id || to_string(bridge_id),
      target_url: normalize_optional_string(Map.get(attrs, :target_url)),
      expires_at: normalize_expires_at(Map.get(attrs, :expires_at)),
      metadata: normalize_metadata(Map.get(attrs, :metadata, %{})),
      raw: Map.get(attrs, :raw)
    })
  end

  defp normalize_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case key_to_atom(key) do
          nil -> acc
          atom -> Map.put(acc, atom, value)
        end

      {_key, _value}, acc ->
        acc
    end)
  end

  defp key_to_atom("bridge_id"), do: :bridge_id
  defp key_to_atom("adapter_name"), do: :adapter_name
  defp key_to_atom("adapter"), do: :adapter_name
  defp key_to_atom("status"), do: :status
  defp key_to_atom("external_id"), do: :external_id
  defp key_to_atom("subscription_id"), do: :subscription_id
  defp key_to_atom("id"), do: :id
  defp key_to_atom("target_url"), do: :target_url
  defp key_to_atom("webhook_url"), do: :target_url
  defp key_to_atom("expires_at"), do: :expires_at
  defp key_to_atom("metadata"), do: :metadata
  defp key_to_atom("raw"), do: :raw
  defp key_to_atom(_), do: nil

  defp subscription_id(attrs) do
    Map.get(attrs, :subscription_id) ||
      Map.get(attrs, :id) ||
      Map.get(attrs, :external_id) ||
      Map.get(attrs, :target_url) ||
      Map.get(attrs, :bridge_id)
  end

  defp normalize_adapter_name(adapter_name) when is_atom(adapter_name) do
    case Atom.to_string(adapter_name) do
      "Elixir." <> _ ->
        adapter_name
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
        |> String.to_atom()

      _ ->
        adapter_name
    end
  end

  defp normalize_adapter_name(adapter_name) when is_binary(adapter_name) do
    String.to_existing_atom(adapter_name)
  rescue
    ArgumentError -> :unknown
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "active" -> :active
      "deleted" -> :deleted
      "disabled" -> :disabled
      "expired" -> :expired
      "manual_action_required" -> :manual_action_required
      "pending" -> :pending
      _unknown -> :unknown
    end
  end

  defp normalize_status(_status), do: :unknown

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_expires_at(%DateTime{} = expires_at), do: expires_at

  defp normalize_expires_at(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_expires_at(_expires_at), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
