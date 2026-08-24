defmodule Jido.Messaging.JidokaContinuityRef do
  @moduledoc """
  Opaque reference to continuity data that Jidoka owns.

  The reference identifies a Jidoka integration, agent, and session. Optional
  request, turn, and snapshot values are identifiers only. The record never
  contains session data, memory, a prompt, or a serialized snapshot.
  """

  alias Jido.Messaging.ContinuityData

  @schema Zoi.struct(
            __MODULE__,
            %{
              integration_id: Zoi.string(),
              jidoka_agent_ref: Zoi.map(),
              session_id: Zoi.string(),
              request_id: Zoi.string() |> Zoi.nullish(),
              turn_id: Zoi.string() |> Zoi.nullish(),
              snapshot_id: Zoi.string() |> Zoi.nullish(),
              expires_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :integration_id,
    :jidoka_agent_ref,
    :session_id,
    :request_id,
    :turn_id,
    :snapshot_id,
    :expires_at
  ]

  @doc "Returns the Zoi schema for JidokaContinuityRef."
  def schema, do: @schema

  @doc "Builds a strict opaque Jidoka continuity reference."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = reference), do: reference |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = ContinuityData.strict_keys!(attrs, @allowed_keys, "Jidoka continuity reference")

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      integration_id: attrs |> ContinuityData.value(:integration_id) |> ContinuityData.required_ref!(:integration_id),
      jidoka_agent_ref: attrs |> ContinuityData.value(:jidoka_agent_ref) |> ContinuityData.jidoka_ref!(),
      session_id: attrs |> ContinuityData.value(:session_id) |> ContinuityData.required_ref!(:session_id),
      request_id: attrs |> ContinuityData.value(:request_id) |> ContinuityData.optional_ref!(:request_id),
      turn_id: attrs |> ContinuityData.value(:turn_id) |> ContinuityData.optional_ref!(:turn_id),
      snapshot_id: attrs |> ContinuityData.value(:snapshot_id) |> ContinuityData.optional_ref!(:snapshot_id),
      expires_at: attrs |> ContinuityData.value(:expires_at) |> ContinuityData.optional_time!(:expires_at)
    })
  end

  def new(_attrs), do: raise(ArgumentError, "Jidoka continuity reference must be a plain map")

  @doc "Returns the stable Jidoka session identity for conflict checks."
  @spec session_key(t()) :: {String.t(), String.t()}
  def session_key(%__MODULE__{} = reference), do: {reference.integration_id, reference.session_id}

  @doc "Removes request, turn, and snapshot identifiers for a terminal link."
  @spec clear_short_refs(t()) :: t()
  def clear_short_refs(%__MODULE__{} = reference) do
    %{reference | request_id: nil, turn_id: nil, snapshot_id: nil}
  end
end
