defmodule Jido.Messaging.Membership do
  @moduledoc """
  Durable room membership for a canonical messaging principal.

  Membership is evidence for membership-based invocation policy. It does not
  grant read, write, transcript, bridge, or invocation actions by itself.
  """

  alias Jido.Messaging.AuthorizationData

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              principal_id: Zoi.string(),
              room_id: Zoi.string(),
              issuer_principal_id: Zoi.string(),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              revision: Zoi.integer() |> Zoi.default(1),
              joined_at: Zoi.struct(DateTime),
              ended_at: Zoi.struct(DateTime) |> Zoi.nullish(),
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

  @doc "Returns the Zoi schema for Membership."
  def schema, do: @schema

  @doc "Creates a durable principal membership."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    revision = AuthorizationData.value(attrs, :revision, 1)

    if not is_integer(revision) or revision < 1 do
      raise ArgumentError, "membership revision must be a positive integer"
    end

    attrs
    |> Map.put(
      :principal_id,
      attrs |> AuthorizationData.value(:principal_id) |> AuthorizationData.required_id!(:principal_id)
    )
    |> Map.put(:room_id, attrs |> AuthorizationData.value(:room_id) |> AuthorizationData.required_id!(:room_id))
    |> Map.put(
      :issuer_principal_id,
      attrs |> AuthorizationData.value(:issuer_principal_id) |> AuthorizationData.required_id!(:issuer_principal_id)
    )
    |> Map.put(:revision, revision)
    |> Map.put(:metadata, attrs |> AuthorizationData.value(:metadata, %{}) |> AuthorizationData.safe_map!(:metadata))
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:joined_at, now)
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Changes membership status and increments its revision."
  @spec transition(t(), status(), DateTime.t()) :: t()
  def transition(%__MODULE__{} = membership, status, changed_at \\ DateTime.utc_now())
      when status in [:active, :suspended, :revoked] do
    ended_at = if status == :active, do: nil, else: changed_at

    %{
      membership
      | status: status,
        revision: membership.revision + 1,
        ended_at: ended_at,
        updated_at: changed_at
    }
  end
end
