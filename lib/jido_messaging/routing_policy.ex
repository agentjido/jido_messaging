defmodule Jido.Messaging.RoutingPolicy do
  @moduledoc """
  Runtime-editable routing policy for outbound bridge delivery decisions.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              delivery_mode: Zoi.enum([:best_effort, :primary, :broadcast]) |> Zoi.default(:best_effort),
              failover_policy: Zoi.enum([:none, :next_available, :broadcast]) |> Zoi.default(:next_available),
              dedupe_scope: Zoi.enum([:message_id, :thread, :room]) |> Zoi.default(:message_id),
              fallback_order: Zoi.array(Zoi.string()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{}),
              revision: Zoi.integer() |> Zoi.default(0),
              inserted_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              updated_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for RoutingPolicy."
  def schema, do: @schema

  @doc """
  Builds a routing policy with defaults.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    now = DateTime.utc_now()
    room_id = attrs[:room_id] || attrs[:id] || raise ArgumentError, "routing policy requires :room_id or :id"

    struct!(__MODULE__, %{
      id: Map.get(attrs, :id, room_id),
      room_id: room_id,
      delivery_mode: Map.get(attrs, :delivery_mode, :best_effort),
      failover_policy: Map.get(attrs, :failover_policy, :next_available),
      dedupe_scope: Map.get(attrs, :dedupe_scope, :message_id),
      fallback_order: Map.get(attrs, :fallback_order, []),
      metadata: Map.get(attrs, :metadata, %{}),
      revision: Map.get(attrs, :revision, 0),
      inserted_at: Map.get(attrs, :inserted_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    })
  end

  @doc "Returns a copy with incremented revision and refreshed update timestamp."
  @spec bump_revision(t()) :: t()
  def bump_revision(%__MODULE__{} = policy) do
    %{policy | revision: policy.revision + 1, updated_at: DateTime.utc_now()}
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
  defp key_to_atom("room_id"), do: :room_id
  defp key_to_atom("delivery_mode"), do: :delivery_mode
  defp key_to_atom("failover_policy"), do: :failover_policy
  defp key_to_atom("dedupe_scope"), do: :dedupe_scope
  defp key_to_atom("fallback_order"), do: :fallback_order
  defp key_to_atom("metadata"), do: :metadata
  defp key_to_atom("revision"), do: :revision
  defp key_to_atom("inserted_at"), do: :inserted_at
  defp key_to_atom("updated_at"), do: :updated_at
  defp key_to_atom(_), do: nil
end
