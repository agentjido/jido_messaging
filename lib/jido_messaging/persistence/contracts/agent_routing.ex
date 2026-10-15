defmodule Jido.Messaging.Persistence.Contracts.AgentRouting do
  @moduledoc """
  Storage contract for agent routing.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.AgentMessagingEndpoint
  alias Jido.Messaging.AgentThreadRoute
  alias Jido.Messaging.RoomMembership

  @type state :: Jido.Messaging.Persistence.state()

  @callback save_agent_messaging_endpoint(state, AgentMessagingEndpoint.t()) ::
              {:ok, AgentMessagingEndpoint.t()} | {:error, term()}

  @callback get_agent_messaging_endpoint(state, String.t()) ::
              {:ok, AgentMessagingEndpoint.t()} | {:error, :not_found}

  @callback get_agent_messaging_endpoint_by_ref(state, String.t()) ::
              {:ok, AgentMessagingEndpoint.t()} | {:error, :not_found}

  @callback list_agent_messaging_endpoints(state, keyword()) ::
              {:ok, [AgentMessagingEndpoint.t()]}

  @callback save_room_membership(state, RoomMembership.t()) ::
              {:ok, RoomMembership.t()} | {:error, term()}

  @callback get_room_membership(state, String.t()) ::
              {:ok, RoomMembership.t()} | {:error, :not_found}

  @callback get_room_membership(state, String.t(), String.t()) ::
              {:ok, RoomMembership.t()} | {:error, :not_found}

  @callback list_room_memberships(state, String.t(), keyword()) ::
              {:ok, [RoomMembership.t()]}

  @callback save_agent_thread_route(state, AgentThreadRoute.t()) ::
              {:ok, AgentThreadRoute.t()} | {:error, term()}

  @callback get_agent_thread_route(state, String.t()) ::
              {:ok, AgentThreadRoute.t()} | {:error, :not_found}

  @callback list_agent_thread_routes(state, String.t(), keyword()) ::
              {:ok, [AgentThreadRoute.t()]}
end
