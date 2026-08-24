defmodule Jido.Messaging.ExternalIdentityBinding do
  @moduledoc """
  Bridge-scoped provider identity bound to one canonical principal.

  The identity key is the full `{channel, bridge_id, external_id}` tuple. Equal
  provider IDs in two bridges are separate identities until trusted application
  code creates an explicit binding to the same principal.
  """

  @assurance_levels [:asserted, :provider_verified, :application_verified, :cryptographically_verified]
  @assurance_rank @assurance_levels |> Enum.with_index() |> Map.new()
  @legacy_timestamp ~U[1970-01-01 00:00:00Z]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              principal_id: Zoi.string(),
              participant_id: Zoi.string(),
              channel: Zoi.string(),
              bridge_id: Zoi.string(),
              external_id: Zoi.string(),
              assurance: Zoi.enum(@assurance_levels) |> Zoi.default(:asserted),
              proof_ref: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:active, :revoked]) |> Zoi.default(:active),
              verified_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              revoked_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type assurance ::
          :asserted | :provider_verified | :application_verified | :cryptographically_verified
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the supported authorship assurance values in increasing order."
  @spec assurance_levels() :: [assurance()]
  def assurance_levels, do: @assurance_levels

  @doc "Returns the Zoi schema for ExternalIdentityBinding."
  def schema, do: @schema

  @doc "Creates a normalized bridge-scoped identity binding."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    channel = attrs |> value(:channel) |> normalize_required(:channel)
    bridge_id = attrs |> value(:bridge_id) |> normalize_required(:bridge_id)
    external_id = attrs |> value(:external_id) |> normalize_required(:external_id)
    now = DateTime.utc_now()

    attrs
    |> Map.put(:channel, channel)
    |> Map.put(:bridge_id, bridge_id)
    |> Map.put(:external_id, external_id)
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Converts a legacy participant binding map into the typed contract."
  @spec from_legacy(map()) :: t()
  def from_legacy(binding) when is_map(binding) do
    participant_id = value(binding, :participant_id)

    new(%{
      id:
        value(binding, :id) ||
          legacy_id_for(
            value(binding, :channel),
            value(binding, :bridge_id),
            value(binding, :external_id)
          ),
      principal_id: value(binding, :principal_id) || participant_id,
      participant_id: participant_id,
      channel: value(binding, :channel),
      bridge_id: value(binding, :bridge_id),
      external_id: value(binding, :external_id),
      assurance: value(binding, :assurance) || :asserted,
      proof_ref: value(binding, :proof_ref),
      status: value(binding, :status) || :active,
      verified_at: value(binding, :verified_at),
      revoked_at: value(binding, :revoked_at),
      metadata: value(binding, :metadata) || %{},
      inserted_at: value(binding, :inserted_at) || @legacy_timestamp,
      updated_at: value(binding, :updated_at) || @legacy_timestamp
    })
  end

  @doc "Merges stronger assurance data without changing the identity scope."
  @spec strengthen(t(), t()) :: t()
  def strengthen(%__MODULE__{} = existing, %__MODULE__{} = candidate) do
    ensure_same_identity!(existing, candidate)

    stronger? = assurance_rank(candidate.assurance) > assurance_rank(existing.assurance)
    adds_proof? = is_nil(existing.proof_ref) and not is_nil(candidate.proof_ref)

    if stronger? or adds_proof? do
      %{
        existing
        | assurance: if(stronger?, do: candidate.assurance, else: existing.assurance),
          proof_ref: candidate.proof_ref || existing.proof_ref,
          verified_at: verified_at(existing, candidate, stronger?),
          updated_at: DateTime.utc_now()
      }
    else
      existing
    end
  end

  @doc "Marks a binding as revoked without deleting its audit identity."
  @spec revoke(t(), DateTime.t()) :: t()
  def revoke(%__MODULE__{} = binding, revoked_at \\ DateTime.utc_now()) do
    %{binding | status: :revoked, revoked_at: revoked_at, updated_at: revoked_at}
  end

  defp ensure_same_identity!(left, right) do
    fields = [:principal_id, :participant_id, :channel, :bridge_id, :external_id]

    if Map.take(left, fields) != Map.take(right, fields) do
      raise ArgumentError, "cannot merge different external identity bindings"
    end
  end

  defp assurance_rank(assurance), do: Map.fetch!(@assurance_rank, assurance)

  defp verified_at(existing, candidate, true),
    do: candidate.verified_at || existing.verified_at || DateTime.utc_now()

  defp verified_at(existing, _candidate, false), do: existing.verified_at

  defp legacy_id_for(channel, bridge_id, external_id) do
    scope = {
      normalize_required(channel, :channel),
      normalize_required(bridge_id, :bridge_id),
      normalize_required(external_id, :external_id)
    }

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(scope))
    "participant_binding:" <> Base.url_encode64(digest, padding: false)
  end

  defp normalize_required(nil, field), do: raise(ArgumentError, "#{field} is required")

  defp normalize_required(value, field) do
    normalized = to_string(value) |> String.trim()
    if normalized == "", do: raise(ArgumentError, "#{field} is required"), else: normalized
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
