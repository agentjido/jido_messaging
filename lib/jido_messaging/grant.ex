defmodule Jido.Messaging.Grant do
  @moduledoc """
  Revisioned durable allow grant for one messaging principal.

  Grants contain only messaging actions and canonical resource scope. They do
  not contain Jidoka tool controls, runtime limits, model policy, or trust data.
  """

  alias Jido.Messaging.{AuthorizationAction, AuthorizationData, AuthorizationScope}

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              principal_id: Zoi.string(),
              issuer_principal_id: Zoi.string(),
              actions: Zoi.array(Zoi.atom()),
              scope: Zoi.struct(AuthorizationScope),
              constraints: Zoi.map() |> Zoi.default(%{"requires_membership" => true}),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              starts_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              expires_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              revision: Zoi.integer() |> Zoi.default(1),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type status :: :active | :suspended | :revoked
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Grant."
  def schema, do: @schema

  @doc "Creates a revisioned messaging grant."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    revision = AuthorizationData.value(attrs, :revision, 1)
    actions = attrs |> AuthorizationData.value(:actions, []) |> normalize_actions!()
    starts_at = AuthorizationData.value(attrs, :starts_at)
    expires_at = AuthorizationData.value(attrs, :expires_at)

    validate_revision!(revision)
    validate_window!(starts_at, expires_at)

    attrs
    |> Map.put(
      :principal_id,
      attrs |> AuthorizationData.value(:principal_id) |> AuthorizationData.required_id!(:principal_id)
    )
    |> Map.put(
      :issuer_principal_id,
      attrs |> AuthorizationData.value(:issuer_principal_id) |> AuthorizationData.required_id!(:issuer_principal_id)
    )
    |> Map.put(:actions, actions)
    |> Map.put(:scope, attrs |> AuthorizationData.value(:scope) |> AuthorizationScope.new())
    |> Map.put(:constraints, attrs |> AuthorizationData.value(:constraints, %{}) |> AuthorizationData.constraints!())
    |> Map.put(:starts_at, starts_at)
    |> Map.put(:expires_at, expires_at)
    |> Map.put(:revision, revision)
    |> Map.put(:metadata, attrs |> AuthorizationData.value(:metadata, %{}) |> AuthorizationData.safe_map!(:metadata))
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Revises mutable grant fields and increments the revision."
  @spec revise(t(), map(), DateTime.t()) :: t()
  def revise(%__MODULE__{} = grant, attrs, changed_at \\ DateTime.utc_now()) when is_map(attrs) do
    base = Map.from_struct(grant)

    mutable =
      [:actions, :scope, :constraints, :status, :starts_at, :expires_at, :metadata]
      |> Enum.reduce(%{}, fn key, result ->
        if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
          Map.put(result, key, AuthorizationData.value(attrs, key))
        else
          result
        end
      end)

    base
    |> Map.merge(mutable)
    |> Map.put(:revision, grant.revision + 1)
    |> Map.put(:updated_at, changed_at)
    |> new()
  end

  @doc "Revokes a grant and increments its revision."
  @spec revoke(t(), DateTime.t()) :: t()
  def revoke(%__MODULE__{} = grant, changed_at \\ DateTime.utc_now()) do
    revise(grant, %{status: :revoked}, changed_at)
  end

  @doc "Tests whether a grant is active at a point in time."
  @spec active_at?(t(), DateTime.t()) :: boolean()
  def active_at?(%__MODULE__{} = grant, %DateTime{} = at) do
    grant.status == :active and not before?(at, grant.starts_at) and before_expiry?(at, grant.expires_at)
  end

  defp normalize_actions!(actions) when is_list(actions) and actions != [] do
    actions
    |> Enum.map(&AuthorizationAction.normalize!/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_actions!(_actions), do: raise(ArgumentError, "grant actions must be a non-empty list")

  defp validate_revision!(revision) when is_integer(revision) and revision > 0, do: :ok
  defp validate_revision!(_revision), do: raise(ArgumentError, "grant revision must be a positive integer")

  defp validate_window!(starts_at, expires_at) do
    if starts_at && expires_at && DateTime.compare(expires_at, starts_at) != :gt do
      raise ArgumentError, "grant expiry must be after its start"
    end
  end

  defp before?(_at, nil), do: false
  defp before?(at, starts_at), do: DateTime.compare(at, starts_at) == :lt
  defp before_expiry?(_at, nil), do: true
  defp before_expiry?(at, expires_at), do: DateTime.compare(at, expires_at) == :lt
end
