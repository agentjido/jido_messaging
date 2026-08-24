defmodule Jido.Messaging.AuthorizationScope do
  @moduledoc """
  Canonical resource scope for a durable messaging grant.

  A scope contains canonical Jido Messaging identifiers. Provider channel and
  thread identifiers stay in `Jido.Messaging.ChatActions.Scope`.
  """

  alias Jido.Messaging.AuthorizationData

  @kinds [:bridge, :room, :thread, :message, :transcript]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum(@kinds),
              bridge_id: Zoi.string() |> Zoi.nullish(),
              room_id: Zoi.string() |> Zoi.nullish(),
              thread_id: Zoi.string() |> Zoi.nullish(),
              message_id: Zoi.string() |> Zoi.nullish(),
              target_principal_id: Zoi.string() |> Zoi.nullish()
            },
            coerce: true
          )

  @type kind :: :bridge | :room | :thread | :message | :transcript
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AuthorizationScope."
  def schema, do: @schema

  @doc "Builds a canonical authorization scope from a struct or plain map."
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = scope), do: scope |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = %{
      kind: normalize_kind!(AuthorizationData.value(attrs, :kind)),
      bridge_id: normalize_optional(attrs, :bridge_id),
      room_id: normalize_optional(attrs, :room_id),
      thread_id: normalize_optional(attrs, :thread_id),
      message_id: normalize_optional(attrs, :message_id),
      target_principal_id: normalize_optional(attrs, :target_principal_id)
    }

    attrs
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
    |> validate!()
  end

  @doc "Returns a stable identity key for persistence and policy lookup."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = scope) do
    [
      "v1",
      Atom.to_string(scope.kind),
      scope.bridge_id,
      scope.room_id,
      scope.thread_id,
      scope.message_id,
      scope.target_principal_id
    ]
    |> Enum.map(fn value ->
      value = value || ""
      "#{byte_size(value)}:#{value}"
    end)
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc "Tests whether a grant or policy scope contains a requested scope."
  @spec contains?(t(), t()) :: boolean()
  def contains?(%__MODULE__{} = granted, %__MODULE__{} = requested) do
    kind_contains?(granted, requested) and
      optional_match?(granted.bridge_id, requested.bridge_id) and
      optional_match?(granted.target_principal_id, requested.target_principal_id)
  end

  @doc "Returns a deterministic specificity rank for grant selection."
  @spec specificity(t()) :: non_neg_integer()
  def specificity(%__MODULE__{kind: kind} = scope) do
    kind_rank = %{bridge: 1, room: 2, thread: 3, transcript: 4, message: 5}
    kind_rank[kind] + present(scope.bridge_id) + present(scope.target_principal_id)
  end

  @doc "Converts the scope to a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = scope) do
    %{
      "kind" => Atom.to_string(scope.kind),
      "bridge_id" => scope.bridge_id,
      "room_id" => scope.room_id,
      "thread_id" => scope.thread_id,
      "message_id" => scope.message_id,
      "target_principal_id" => scope.target_principal_id
    }
  end

  defp validate!(%__MODULE__{kind: :bridge, bridge_id: bridge_id} = scope) when is_binary(bridge_id),
    do: forbid_fields!(scope, [:room_id, :thread_id, :message_id])

  defp validate!(%__MODULE__{kind: :room, room_id: room_id} = scope) when is_binary(room_id),
    do: forbid_fields!(scope, [:thread_id, :message_id])

  defp validate!(%__MODULE__{kind: :thread, room_id: room_id, thread_id: thread_id} = scope)
       when is_binary(room_id) and is_binary(thread_id),
       do: forbid_fields!(scope, [:message_id])

  defp validate!(%__MODULE__{kind: :message, room_id: room_id, message_id: message_id} = scope)
       when is_binary(room_id) and is_binary(message_id),
       do: scope

  defp validate!(%__MODULE__{kind: :transcript, room_id: room_id} = scope) when is_binary(room_id),
    do: forbid_fields!(scope, [:message_id])

  defp validate!(%__MODULE__{kind: kind}),
    do: raise(ArgumentError, "authorization scope #{kind} is missing required identifiers")

  defp forbid_fields!(scope, fields) do
    if Enum.any?(fields, &Map.get(scope, &1)) do
      raise ArgumentError, "authorization scope contains fields that are not valid for #{scope.kind}"
    end

    scope
  end

  defp kind_contains?(%__MODULE__{kind: :bridge, bridge_id: id}, %__MODULE__{kind: :bridge, bridge_id: id}),
    do: true

  defp kind_contains?(%__MODULE__{kind: :room, room_id: room_id}, requested) do
    requested.kind in [:room, :thread, :message, :transcript] and requested.room_id == room_id
  end

  defp kind_contains?(%__MODULE__{kind: :thread, room_id: room_id, thread_id: thread_id}, requested) do
    requested.kind in [:thread, :message, :transcript] and requested.room_id == room_id and
      requested.thread_id == thread_id
  end

  defp kind_contains?(%__MODULE__{kind: :message} = granted, %__MODULE__{kind: :message} = requested) do
    granted.room_id == requested.room_id and granted.thread_id == requested.thread_id and
      granted.message_id == requested.message_id
  end

  defp kind_contains?(%__MODULE__{kind: :transcript} = granted, %__MODULE__{kind: :transcript} = requested) do
    granted.room_id == requested.room_id and optional_match?(granted.thread_id, requested.thread_id)
  end

  defp kind_contains?(_granted, _requested), do: false

  defp optional_match?(nil, _requested), do: true
  defp optional_match?(value, value), do: true
  defp optional_match?(_granted, _requested), do: false

  defp present(nil), do: 0
  defp present(_value), do: 1

  defp normalize_optional(attrs, key),
    do: attrs |> AuthorizationData.value(key) |> AuthorizationData.optional_id!(key)

  defp normalize_kind!(kind) when kind in @kinds, do: kind

  defp normalize_kind!(kind) when is_binary(kind) do
    Enum.find(@kinds, &(Atom.to_string(&1) == kind)) || raise ArgumentError, "invalid authorization scope kind"
  end

  defp normalize_kind!(_kind), do: raise(ArgumentError, "invalid authorization scope kind")
end
