defmodule Jido.Messaging.Principal do
  @moduledoc """
  Canonical messaging identity for a participant.

  A principal separates identity lifecycle and controller data from the chat
  presentation fields on `Jido.Chat.Participant`. The principal ID is equal to
  the participant ID during the additive compatibility phase.

  `agent_ref` is an opaque external reference. A Jidoka integration can use it
  to identify a Jidoka agent, but this module does not contain an executable
  agent definition or runtime state.
  """

  alias Jido.Chat.Participant

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              participant_id: Zoi.string(),
              type: Zoi.enum([:human, :agent, :system]),
              controller_principal_id: Zoi.string() |> Zoi.nullish(),
              verification_state: Zoi.enum([:unverified, :verified, :revoked]) |> Zoi.default(:unverified),
              credential_state: Zoi.enum([:none, :active, :rotating, :revoked]) |> Zoi.default(:none),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              agent_ref: Zoi.map() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Principal."
  def schema, do: @schema

  @doc "Creates a principal whose ID is the canonical participant ID."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    participant_id = value(attrs, :participant_id)
    id = value(attrs, :id) || participant_id

    if is_binary(participant_id) and is_binary(id) and id != participant_id do
      raise ArgumentError, "principal id must equal participant_id during the compatibility phase"
    end

    now = DateTime.utc_now()

    attrs
    |> normalize_agent_ref()
    |> validate_agent_ref_type()
    |> Map.put_new(:id, id)
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Builds a safe principal projection from a participant."
  @spec from_participant(Participant.t()) :: t()
  def from_participant(%Participant{} = participant) do
    new(%{
      id: participant.id,
      participant_id: participant.id,
      type: participant.type
    })
  end

  defp normalize_agent_ref(attrs) do
    case value(attrs, :agent_ref) do
      nil ->
        attrs

      reference when is_map(reference) ->
        system = value(reference, :system)
        external_id = value(reference, :id)
        allowed_keys = [:system, :id, "system", "id"]
        extra_keys = Map.keys(reference) -- allowed_keys

        if extra_keys == [] and present_string?(system) and present_string?(external_id) do
          Map.put(attrs, :agent_ref, %{
            "system" => String.trim(system),
            "id" => String.trim(external_id)
          })
        else
          raise ArgumentError, "agent_ref permits only string system and id fields"
        end

      _other ->
        raise ArgumentError, "agent_ref must be an opaque map"
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp validate_agent_ref_type(attrs) do
    case {value(attrs, :agent_ref), value(attrs, :type)} do
      {nil, _type} -> attrs
      {_reference, type} when type in [:agent, "agent"] -> attrs
      {_reference, _type} -> raise ArgumentError, "agent_ref is valid only for an agent principal"
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
