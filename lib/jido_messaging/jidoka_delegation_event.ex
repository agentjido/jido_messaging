defmodule Jido.Messaging.JidokaDelegationEvent do
  @moduledoc """
  Immutable messaging record for a Jidoka-emitted delegation observation.

  The record carries identities, authorization subjects, canonical message
  references, and a bounded transport trace. It does not implement subagent or
  handoff state and cannot carry Jidoka context or operation output.
  """

  alias Jido.Messaging.{
    DelegationData,
    JidokaDelegationRef,
    JidokaEmissionRef
  }

  @actions [:requested, :accepted, :cancelled, :result, :route_changed, :route_cleared]
  @maximum_hops 16

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              action: Zoi.enum(@actions),
              room_id: Zoi.string(),
              thread_id: Zoi.string(),
              source_principal_id: Zoi.string(),
              target_principal_id: Zoi.string(),
              delegation_ref: Zoi.struct(JidokaDelegationRef),
              emission_ref: Zoi.struct(JidokaEmissionRef),
              related_message_ids: Zoi.array(Zoi.string()),
              route_ref: Zoi.string() |> Zoi.nullish(),
              reason_code: Zoi.string() |> Zoi.nullish(),
              transport_id: Zoi.string(),
              visited_nodes: Zoi.array(Zoi.string()),
              observed_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type action :: :requested | :accepted | :cancelled | :result | :route_changed | :route_cleared
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :action,
    :room_id,
    :thread_id,
    :source_principal_id,
    :target_principal_id,
    :delegation_ref,
    :emission_ref,
    :related_message_ids,
    :route_ref,
    :reason_code,
    :transport_id,
    :visited_nodes
  ]

  @doc "Returns the Zoi schema for JidokaDelegationEvent."
  def schema, do: @schema

  @doc "Builds a strict messaging record from Jidoka adapter input."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = DelegationData.strict_keys!(attrs, @allowed_keys, "Jidoka delegation event")

    action = attrs |> DelegationData.value(:action) |> DelegationData.enum!(@actions, :delegation_action)
    delegation_ref = attrs |> DelegationData.value(:delegation_ref) |> JidokaDelegationRef.new()
    emission_ref = attrs |> DelegationData.value(:emission_ref) |> JidokaEmissionRef.new()
    route_ref = attrs |> DelegationData.value(:route_ref) |> DelegationData.optional_ref!(:route_ref)
    reason_code = attrs |> DelegationData.value(:reason_code) |> DelegationData.optional_code!(:reason_code)

    related_message_ids =
      attrs
      |> DelegationData.value(:related_message_ids, [])
      |> DelegationData.ref_list!(:related_message_id, maximum: 50)

    visited_nodes =
      attrs
      |> DelegationData.value(:visited_nodes, [])
      |> DelegationData.ref_list!(:visited_node, maximum: @maximum_hops)

    :ok = validate_action!(action, delegation_ref, emission_ref, route_ref, reason_code)
    :ok = validate_identity_alignment!(delegation_ref, emission_ref)

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      id: event_id(action, delegation_ref.id, emission_ref.id),
      action: action,
      room_id: attrs |> DelegationData.value(:room_id) |> DelegationData.required_ref!(:room_id),
      thread_id: attrs |> DelegationData.value(:thread_id) |> DelegationData.required_ref!(:thread_id),
      source_principal_id:
        attrs |> DelegationData.value(:source_principal_id) |> DelegationData.required_ref!(:source_principal_id),
      target_principal_id:
        attrs |> DelegationData.value(:target_principal_id) |> DelegationData.required_ref!(:target_principal_id),
      delegation_ref: delegation_ref,
      emission_ref: emission_ref,
      related_message_ids: related_message_ids,
      route_ref: route_ref,
      reason_code: reason_code,
      transport_id: attrs |> DelegationData.value(:transport_id) |> DelegationData.required_ref!(:transport_id),
      visited_nodes: visited_nodes,
      observed_at: DateTime.utc_now()
    })
    |> validate_principals!()
  end

  def new(_attrs), do: raise(ArgumentError, "Jidoka delegation event must be a plain map")

  @doc "Adds one transport node or rejects a loop or excessive hop count."
  @spec enter(t(), String.t()) :: {:ok, t()} | {:error, :delegation_transport_loop | :delegation_hop_limit}
  def enter(%__MODULE__{} = event, node_id) do
    node_id = DelegationData.required_ref!(node_id, :transport_node)

    cond do
      node_id in event.visited_nodes ->
        {:error, :delegation_transport_loop}

      length(event.visited_nodes) >= @maximum_hops ->
        {:error, :delegation_hop_limit}

      true ->
        {:ok, %{event | visited_nodes: event.visited_nodes ++ [node_id]}}
    end
  end

  @doc "Tests whether two records contain the same immutable transport data."
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = left, %__MODULE__{} = right) do
    Map.delete(Map.from_struct(left), :observed_at) ==
      Map.delete(Map.from_struct(right), :observed_at)
  end

  @doc "Returns the unique Jidoka emission claim for duplicate checks."
  @spec emission_claim(t()) :: String.t()
  def emission_claim(%__MODULE__{} = event), do: event.emission_ref.id

  @doc "Tests whether the event can cause message delivery or a route change."
  @spec deliverable?(t()) :: boolean()
  def deliverable?(%__MODULE__{action: action}),
    do: action in [:requested, :accepted, :result, :route_changed]

  @doc "Returns the maximum supported transport hops."
  @spec maximum_hops() :: pos_integer()
  def maximum_hops, do: @maximum_hops

  defp validate_action!(:requested, _delegation, %{source: :event}, nil, _reason), do: :ok
  defp validate_action!(:cancelled, _delegation, %{source: :event}, nil, reason) when is_binary(reason), do: :ok
  defp validate_action!(:result, %{kind: :subagent}, %{source: :operation_result}, nil, _reason), do: :ok
  defp validate_action!(:accepted, %{kind: :handoff}, %{source: :handoff}, nil, _reason), do: :ok

  defp validate_action!(:route_changed, %{kind: :handoff}, %{source: :handoff}, route_ref, _reason)
       when is_binary(route_ref),
       do: :ok

  defp validate_action!(:route_cleared, %{kind: :handoff}, %{source: :event}, route_ref, _reason)
       when is_binary(route_ref),
       do: :ok

  defp validate_action!(_action, _delegation, _emission, _route_ref, _reason),
    do: raise(ArgumentError, "delegation action does not match its Jidoka source")

  defp validate_identity_alignment!(%{kind: :handoff, handoff_id: handoff_id}, %{
         source: :handoff,
         handoff_id: handoff_id
       }),
       do: :ok

  defp validate_identity_alignment!(
         %{kind: :subagent, effect_id: effect_id} = delegation,
         %{
           source: :operation_result,
           effect_id: effect_id
         } = emission
       ) do
    validate_optional_identity!(delegation.request_id, emission.request_id)
  end

  defp validate_identity_alignment!(delegation, %{source: :event} = emission) do
    with :ok <- validate_optional_identity!(delegation.request_id, emission.request_id) do
      validate_optional_identity!(delegation.effect_id, emission.effect_id)
    end
  end

  defp validate_identity_alignment!(_delegation, _emission),
    do: raise(ArgumentError, "delegation and emission identities do not match")

  defp validate_optional_identity!(nil, _emission_value), do: :ok
  defp validate_optional_identity!(value, value), do: :ok

  defp validate_optional_identity!(_delegation_value, _emission_value),
    do: raise(ArgumentError, "delegation and emission identities do not match")

  defp validate_principals!(%__MODULE__{} = event) do
    if event.source_principal_id == event.target_principal_id do
      raise ArgumentError, "source and target principals must be different"
    end

    event
  end

  defp event_id(action, delegation_id, emission_id) do
    DelegationData.stable_id("jde", {1, action, delegation_id, emission_id})
  end
end
