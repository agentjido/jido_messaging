defmodule Jido.Messaging.AgentEndpointTarget do
  @moduledoc """
  Resolved endpoint, membership, and route for one messaging thread.

  This is a messaging projection. It does not load or start a Jidoka agent.
  """

  alias Jido.Messaging.{AgentMessagingEndpoint, AgentThreadRoute, RoomMembership}

  @enforce_keys [:endpoint, :membership, :route]
  defstruct [:endpoint, :membership, :route]

  @type t :: %__MODULE__{
          endpoint: AgentMessagingEndpoint.t(),
          membership: RoomMembership.t(),
          route: AgentThreadRoute.t()
        }

  @doc "Builds a target after checking endpoint, membership, and route relations."
  @spec new(AgentMessagingEndpoint.t(), RoomMembership.t(), AgentThreadRoute.t()) ::
          {:ok, t()} | {:error, term()}
  def new(
        %AgentMessagingEndpoint{} = endpoint,
        %RoomMembership{} = membership,
        %AgentThreadRoute{} = route
      ) do
    cond do
      membership.endpoint_id != endpoint.id ->
        {:error, :endpoint_membership_mismatch}

      membership.principal_id != endpoint.principal_id ->
        {:error, :endpoint_principal_mismatch}

      route.endpoint_id != endpoint.id ->
        {:error, :endpoint_route_mismatch}

      route.room_id != membership.room_id ->
        {:error, :membership_route_room_mismatch}

      true ->
        {:ok, %__MODULE__{endpoint: endpoint, membership: membership, route: route}}
    end
  end
end
