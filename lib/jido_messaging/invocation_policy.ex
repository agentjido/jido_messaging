defmodule Jido.Messaging.InvocationPolicy do
  @moduledoc """
  Durable messaging policy for who can invoke one agent principal.

  The policy is an additional messaging gate after an `:invoke_agent` grant.
  It does not copy or replace Jidoka runtime controls.
  """

  alias Jido.Messaging.{AuthorizationData, AuthorizationScope}

  @modes [:controller_only, :allowlist, :room_members, :anyone, :nobody]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              target_principal_id: Zoi.string(),
              issuer_principal_id: Zoi.string(),
              scope: Zoi.struct(AuthorizationScope),
              mode: Zoi.enum(@modes),
              controller_principal_id: Zoi.string() |> Zoi.nullish(),
              allowed_principal_ids: Zoi.array(Zoi.string()) |> Zoi.default([]),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              expires_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              revision: Zoi.integer() |> Zoi.default(1),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type mode :: :controller_only | :allowlist | :room_members | :anyone | :nobody
  @type status :: :active | :suspended | :revoked
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for InvocationPolicy."
  def schema, do: @schema

  @doc "Creates an invocation policy for an agent principal and scope."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    revision = AuthorizationData.value(attrs, :revision, 1)
    mode = normalize_mode!(AuthorizationData.value(attrs, :mode))
    scope = attrs |> AuthorizationData.value(:scope) |> AuthorizationScope.new()

    controller =
      attrs
      |> AuthorizationData.value(:controller_principal_id)
      |> AuthorizationData.optional_id!(:controller_principal_id)

    allowed =
      attrs
      |> AuthorizationData.value(:allowed_principal_ids, [])
      |> AuthorizationData.id_list!(:allowed_principal_ids)

    validate_revision!(revision)
    validate_scope!(scope)
    validate_mode!(mode, controller, allowed)

    attrs
    |> Map.put(
      :target_principal_id,
      attrs |> AuthorizationData.value(:target_principal_id) |> AuthorizationData.required_id!(:target_principal_id)
    )
    |> Map.put(
      :issuer_principal_id,
      attrs |> AuthorizationData.value(:issuer_principal_id) |> AuthorizationData.required_id!(:issuer_principal_id)
    )
    |> Map.put(:scope, scope)
    |> Map.put(:mode, mode)
    |> Map.put(:controller_principal_id, controller)
    |> Map.put(:allowed_principal_ids, allowed)
    |> Map.put(:revision, revision)
    |> Map.put(:metadata, attrs |> AuthorizationData.value(:metadata, %{}) |> AuthorizationData.safe_map!(:metadata))
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Revises mutable policy fields and increments the revision."
  @spec revise(t(), map(), DateTime.t()) :: t()
  def revise(%__MODULE__{} = policy, attrs, changed_at \\ DateTime.utc_now()) when is_map(attrs) do
    mutable =
      [:mode, :controller_principal_id, :allowed_principal_ids, :status, :expires_at, :metadata]
      |> Enum.reduce(%{}, fn key, result ->
        if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
          Map.put(result, key, AuthorizationData.value(attrs, key))
        else
          result
        end
      end)

    policy
    |> Map.from_struct()
    |> Map.merge(mutable)
    |> Map.put(:revision, policy.revision + 1)
    |> Map.put(:updated_at, changed_at)
    |> new()
  end

  @doc "Revokes a policy and increments its revision."
  @spec revoke(t(), DateTime.t()) :: t()
  def revoke(%__MODULE__{} = policy, changed_at \\ DateTime.utc_now()) do
    revise(policy, %{status: :revoked}, changed_at)
  end

  @doc "Tests whether a policy is active at a point in time."
  @spec active_at?(t(), DateTime.t()) :: boolean()
  def active_at?(%__MODULE__{status: :active, expires_at: nil}, %DateTime{}), do: true

  def active_at?(%__MODULE__{status: :active, expires_at: expires_at}, %DateTime{} = at),
    do: DateTime.compare(at, expires_at) == :lt

  def active_at?(%__MODULE__{}, %DateTime{}), do: false

  defp validate_scope!(%AuthorizationScope{kind: kind}) when kind in [:room, :thread], do: :ok
  defp validate_scope!(_scope), do: raise(ArgumentError, "invocation policy scope must be a room or thread")

  defp validate_mode!(:controller_only, controller, []) when is_binary(controller), do: :ok
  defp validate_mode!(:allowlist, nil, allowed) when allowed != [], do: :ok
  defp validate_mode!(:room_members, nil, []), do: :ok
  defp validate_mode!(mode, nil, []) when mode in [:anyone, :nobody], do: :ok
  defp validate_mode!(mode, _controller, _allowed), do: raise(ArgumentError, "invocation policy #{mode} is incomplete")

  defp validate_revision!(revision) when is_integer(revision) and revision > 0, do: :ok
  defp validate_revision!(_revision), do: raise(ArgumentError, "policy revision must be a positive integer")

  defp normalize_mode!(mode) when mode in @modes, do: mode

  defp normalize_mode!(mode) when is_binary(mode) do
    Enum.find(@modes, &(Atom.to_string(&1) == mode)) || raise ArgumentError, "invalid invocation policy mode"
  end

  defp normalize_mode!(_mode), do: raise(ArgumentError, "invalid invocation policy mode")
end
