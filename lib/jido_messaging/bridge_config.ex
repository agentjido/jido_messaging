defmodule Jido.Messaging.BridgeConfig do
  @moduledoc """
  Runtime-editable bridge configuration for adapter-backed ingress/egress.

  `BridgeConfig` is the control-plane definition for a single external adapter bridge.
  """

  alias Jido.Chat.Adapter
  alias Jido.Messaging.DeliveryPolicy

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              adapter_module: Zoi.module(),
              credentials: Zoi.map() |> Zoi.default(%{}),
              opts: Zoi.map() |> Zoi.default(%{}),
              enabled: Zoi.boolean() |> Zoi.default(true),
              capabilities: Zoi.map() |> Zoi.default(%{}),
              delivery_policy: Zoi.struct(DeliveryPolicy) |> Zoi.default(DeliveryPolicy.new(%{})),
              revision: Zoi.integer() |> Zoi.default(0),
              inserted_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              updated_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for BridgeConfig."
  def schema, do: @schema

  @doc """
  Builds a bridge config with defaults and derived capabilities.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    adapter_module = Map.fetch!(attrs, :adapter_module)
    now = DateTime.utc_now()

    struct!(__MODULE__, %{
      id: Map.get(attrs, :id, generate_id()),
      adapter_module: adapter_module,
      credentials: Map.get(attrs, :credentials, %{}),
      opts: Map.get(attrs, :opts, %{}),
      enabled: Map.get(attrs, :enabled, true),
      capabilities: Map.get(attrs, :capabilities, Adapter.capabilities(adapter_module)),
      delivery_policy: normalize_delivery_policy(Map.get(attrs, :delivery_policy, %{})),
      revision: Map.get(attrs, :revision, 0),
      inserted_at: Map.get(attrs, :inserted_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    })
  end

  @doc "Returns a copy with incremented revision and refreshed update timestamp."
  @spec bump_revision(t()) :: t()
  def bump_revision(%__MODULE__{} = config) do
    %{config | revision: config.revision + 1, updated_at: DateTime.utc_now()}
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.reduce(%{}, fn
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

  defp key_to_atom("id"), do: :id
  defp key_to_atom("adapter_module"), do: :adapter_module
  defp key_to_atom("credentials"), do: :credentials
  defp key_to_atom("opts"), do: :opts
  defp key_to_atom("enabled"), do: :enabled
  defp key_to_atom("capabilities"), do: :capabilities
  defp key_to_atom("delivery_policy"), do: :delivery_policy
  defp key_to_atom("revision"), do: :revision
  defp key_to_atom("inserted_at"), do: :inserted_at
  defp key_to_atom("updated_at"), do: :updated_at
  defp key_to_atom(_), do: nil

  defp generate_id do
    "bridge_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp normalize_delivery_policy(%DeliveryPolicy{} = policy), do: policy
  defp normalize_delivery_policy(attrs) when is_map(attrs), do: DeliveryPolicy.new(attrs)
  defp normalize_delivery_policy(_other), do: DeliveryPolicy.new(%{})
end
