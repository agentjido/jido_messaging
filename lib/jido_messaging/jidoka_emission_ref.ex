defmodule Jido.Messaging.JidokaEmissionRef do
  @moduledoc """
  Reference to a canonical record or event that Jidoka emitted.

  Jidoka events use request ID and sequence as their stable identity. Handoff
  records use the canonical handoff ID. Operation results use request and
  effect IDs. This type stores those identities without copying event data or
  operation output.
  """

  alias Jido.Messaging.DelegationData

  @sources [:event, :handoff, :operation_result]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              source: Zoi.enum(@sources),
              event: Zoi.string(),
              request_id: Zoi.string() |> Zoi.nullish(),
              sequence: Zoi.integer() |> Zoi.nullish(),
              loop_index: Zoi.integer() |> Zoi.nullish(),
              effect_id: Zoi.string() |> Zoi.nullish(),
              handoff_id: Zoi.string() |> Zoi.nullish()
            },
            coerce: true
          )

  @type source :: :event | :handoff | :operation_result
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [:source, :event, :request_id, :sequence, :loop_index, :effect_id, :handoff_id]

  @doc "Returns the Zoi schema for JidokaEmissionRef."
  def schema, do: @schema

  @doc "Builds a strict reference to Jidoka-emitted data."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = reference), do: reference |> Map.from_struct() |> Map.delete(:id) |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = DelegationData.strict_keys!(attrs, @allowed_keys, "Jidoka emission reference")

    source = attrs |> DelegationData.value(:source) |> DelegationData.enum!(@sources, :emission_source)
    event = attrs |> DelegationData.value(:event) |> DelegationData.required_code!(:jidoka_event)
    request_id = attrs |> DelegationData.value(:request_id) |> DelegationData.optional_ref!(:request_id)
    sequence = attrs |> DelegationData.value(:sequence) |> DelegationData.optional_non_negative!(:sequence)
    loop_index = attrs |> DelegationData.value(:loop_index) |> DelegationData.optional_non_negative!(:loop_index)
    effect_id = attrs |> DelegationData.value(:effect_id) |> DelegationData.optional_ref!(:effect_id)
    handoff_id = attrs |> DelegationData.value(:handoff_id) |> DelegationData.optional_ref!(:handoff_id)

    :ok = validate_source!(source, event, request_id, sequence, loop_index, effect_id, handoff_id)

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      id: emission_id(source, event, request_id, sequence, loop_index, effect_id, handoff_id),
      source: source,
      event: event,
      request_id: request_id,
      sequence: sequence,
      loop_index: loop_index,
      effect_id: effect_id,
      handoff_id: handoff_id
    })
  end

  def new(_attrs), do: raise(ArgumentError, "Jidoka emission reference must be a plain map")

  defp validate_source!(:event, _event, request_id, sequence, _loop, _effect, nil)
       when is_binary(request_id) and is_integer(sequence),
       do: :ok

  defp validate_source!(:handoff, "handoff", _request, nil, nil, nil, handoff_id)
       when is_binary(handoff_id),
       do: :ok

  defp validate_source!(:operation_result, "operation_result", request_id, nil, loop, effect_id, nil)
       when is_binary(request_id) and is_binary(effect_id) and (is_nil(loop) or is_integer(loop)),
       do: :ok

  defp validate_source!(_source, _event, _request, _sequence, _loop, _effect, _handoff),
    do: raise(ArgumentError, "emission fields do not match the Jidoka source contract")

  defp emission_id(:event, _event, request_id, sequence, _loop, _effect, nil) do
    DelegationData.stable_id("jem", {1, :event, request_id, sequence})
  end

  defp emission_id(:handoff, "handoff", _request, nil, nil, nil, handoff_id) do
    DelegationData.stable_id("jem", {1, :handoff, handoff_id})
  end

  defp emission_id(:operation_result, "operation_result", request, nil, loop, effect, nil) do
    DelegationData.stable_id("jem", {1, :operation_result, request, loop, effect})
  end
end
