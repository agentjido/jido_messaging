defmodule Jido.Messaging.JidokaDelegationRef do
  @moduledoc """
  Opaque identity for a Jidoka subagent call or handoff.

  A subagent ID is the Jidoka effect ID. A handoff ID is the canonical
  `Jidoka.Handoff.id`. This record does not contain tasks, context, results,
  ownership state, or executable agent modules.
  """

  alias Jido.Messaging.DelegationData

  @kinds [:subagent, :handoff]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum(@kinds),
              id: Zoi.string(),
              conversation_id: Zoi.string() |> Zoi.nullish(),
              handoff_id: Zoi.string() |> Zoi.nullish(),
              request_id: Zoi.string() |> Zoi.nullish(),
              turn_id: Zoi.string() |> Zoi.nullish(),
              effect_id: Zoi.string() |> Zoi.nullish(),
              source_agent_ref: Zoi.map(),
              target_agent_ref: Zoi.map()
            },
            coerce: true
          )

  @type kind :: :subagent | :handoff
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :kind,
    :id,
    :conversation_id,
    :handoff_id,
    :request_id,
    :turn_id,
    :effect_id,
    :source_agent_ref,
    :target_agent_ref
  ]

  @doc "Returns the Zoi schema for JidokaDelegationRef."
  def schema, do: @schema

  @doc "Builds a strict opaque Jidoka delegation reference."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = reference), do: reference |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = DelegationData.strict_keys!(attrs, @allowed_keys, "Jidoka delegation reference")

    kind = attrs |> DelegationData.value(:kind) |> DelegationData.enum!(@kinds, :delegation_kind)
    id = attrs |> DelegationData.value(:id) |> DelegationData.required_ref!(:delegation_id)

    conversation_id =
      attrs |> DelegationData.value(:conversation_id) |> DelegationData.optional_ref!(:conversation_id)

    handoff_id = attrs |> DelegationData.value(:handoff_id) |> DelegationData.optional_ref!(:handoff_id)
    request_id = attrs |> DelegationData.value(:request_id) |> DelegationData.optional_ref!(:request_id)
    turn_id = attrs |> DelegationData.value(:turn_id) |> DelegationData.optional_ref!(:turn_id)
    effect_id = attrs |> DelegationData.value(:effect_id) |> DelegationData.optional_ref!(:effect_id)

    source_agent_ref =
      attrs |> DelegationData.value(:source_agent_ref) |> DelegationData.jidoka_ref!(:source_agent_ref)

    target_agent_ref =
      attrs |> DelegationData.value(:target_agent_ref) |> DelegationData.jidoka_ref!(:target_agent_ref)

    :ok = validate_kind!(kind, id, conversation_id, handoff_id, effect_id)
    :ok = validate_agents!(source_agent_ref, target_agent_ref)

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      kind: kind,
      id: id,
      conversation_id: conversation_id,
      handoff_id: handoff_id,
      request_id: request_id,
      turn_id: turn_id,
      effect_id: effect_id,
      source_agent_ref: source_agent_ref,
      target_agent_ref: target_agent_ref
    })
  end

  def new(_attrs), do: raise(ArgumentError, "Jidoka delegation reference must be a plain map")

  defp validate_kind!(:subagent, id, _conversation_id, nil, effect_id)
       when is_binary(effect_id) and id == effect_id,
       do: :ok

  defp validate_kind!(:handoff, id, conversation_id, handoff_id, _effect_id)
       when is_binary(conversation_id) and is_binary(handoff_id) and id == handoff_id,
       do: :ok

  defp validate_kind!(_kind, _id, _conversation_id, _handoff_id, _effect_id),
    do: raise(ArgumentError, "delegation fields do not match the Jidoka kind contract")

  defp validate_agents!(source, target) do
    if source["id"] == target["id"] do
      raise ArgumentError, "source and target Jidoka agents must be different"
    end

    :ok
  end
end
