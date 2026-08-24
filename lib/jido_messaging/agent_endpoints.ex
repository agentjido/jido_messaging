defmodule Jido.Messaging.AgentEndpoints do
  @moduledoc false

  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    AgentEndpointData,
    AgentEndpointTarget,
    AgentMessagingEndpoint,
    AgentThreadRoute,
    RoomMembership,
    Runtime,
    Thread
  }

  @doc false
  @spec create_endpoint(atom(), map()) :: {:ok, AgentMessagingEndpoint.t()} | {:error, term()}
  def create_endpoint(runtime, attrs) when is_map(attrs) do
    endpoint = AgentMessagingEndpoint.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_agent_messaging_endpoint, 2),
         :ok <- require_callback(persistence, :get_agent_messaging_endpoint_by_ref, 2),
         :ok <- validate_agent_participant(persistence, state, endpoint.principal_id),
         :ok <- ensure_initial_endpoint(endpoint) do
      create_or_get_endpoint(persistence, state, endpoint)
    end
  end

  @doc false
  @spec save_endpoint(atom(), AgentMessagingEndpoint.t()) ::
          {:ok, AgentMessagingEndpoint.t()} | {:error, term()}
  def save_endpoint(runtime, %AgentMessagingEndpoint{} = endpoint) do
    endpoint = endpoint |> Map.from_struct() |> AgentMessagingEndpoint.new()
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_agent_messaging_endpoint, 2),
         :ok <- validate_agent_participant(persistence, state, endpoint.principal_id) do
      persistence.save_agent_messaging_endpoint(state, endpoint)
    end
  end

  @doc false
  @spec get_endpoint(atom(), String.t()) :: {:ok, AgentMessagingEndpoint.t()} | {:error, term()}
  def get_endpoint(runtime, endpoint_id) when is_binary(endpoint_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_agent_messaging_endpoint, 2) do
      persistence.get_agent_messaging_endpoint(state, endpoint_id)
    end
  end

  @doc false
  @spec get_endpoint_by_ref(atom(), String.t()) ::
          {:ok, AgentMessagingEndpoint.t()} | {:error, term()}
  def get_endpoint_by_ref(runtime, jidoka_agent_id) when is_binary(jidoka_agent_id) do
    jidoka_agent_id = AgentEndpointData.normalize_required!(jidoka_agent_id, :jidoka_agent_id)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_agent_messaging_endpoint_by_ref, 2) do
      persistence.get_agent_messaging_endpoint_by_ref(state, jidoka_agent_id)
    end
  end

  @doc false
  @spec list_endpoints(atom(), keyword()) :: {:ok, [AgentMessagingEndpoint.t()]} | {:error, term()}
  def list_endpoints(runtime, opts) when is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :list_agent_messaging_endpoints, 2) do
      persistence.list_agent_messaging_endpoints(state, opts)
    end
  end

  @doc false
  @spec set_availability(atom(), String.t(), AgentMessagingEndpoint.availability(), keyword()) ::
          {:ok, AgentMessagingEndpoint.t()} | {:error, term()}
  def set_availability(runtime, endpoint_id, availability, opts)
      when is_binary(endpoint_id) and is_list(opts) do
    with {:ok, endpoint} <- get_endpoint(runtime, endpoint_id),
         {:ok, endpoint} <- AgentMessagingEndpoint.set_availability(endpoint, availability, opts) do
      save_endpoint(runtime, endpoint)
    end
  end

  @doc false
  @spec revoke_endpoint(atom(), String.t(), keyword()) ::
          {:ok, AgentMessagingEndpoint.t()} | {:error, term()}
  def revoke_endpoint(runtime, endpoint_id, opts) when is_binary(endpoint_id) and is_list(opts) do
    with {:ok, endpoint} <- get_endpoint(runtime, endpoint_id) do
      revoked_at = Keyword.get(opts, :revoked_at, DateTime.utc_now())
      save_endpoint(runtime, AgentMessagingEndpoint.revoke(endpoint, revoked_at))
    end
  end

  @doc false
  @spec add_endpoint_to_room(atom(), String.t(), String.t(), keyword()) ::
          {:ok, RoomMembership.t()} | {:error, term()}
  def add_endpoint_to_room(runtime, endpoint_id, room_id, opts)
      when is_binary(endpoint_id) and is_binary(room_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_room_membership, 2),
         :ok <- require_callback(persistence, :get_room_membership, 3),
         {:ok, _room} <- persistence.get_room(state, room_id),
         {:ok, %AgentMessagingEndpoint{status: :active} = endpoint} <- get_endpoint(runtime, endpoint_id),
         {:ok, membership} <- get_or_build_membership(persistence, state, endpoint, room_id, opts) do
      save_or_get_membership(persistence, state, membership)
    else
      {:ok, %AgentMessagingEndpoint{status: status}} -> {:error, {:endpoint_inactive, status}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec get_membership(atom(), String.t()) :: {:ok, RoomMembership.t()} | {:error, term()}
  def get_membership(runtime, membership_id) when is_binary(membership_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_room_membership, 2) do
      persistence.get_room_membership(state, membership_id)
    end
  end

  @doc false
  @spec list_memberships(atom(), String.t(), keyword()) ::
          {:ok, [RoomMembership.t()]} | {:error, term()}
  def list_memberships(runtime, room_id, opts) when is_binary(room_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :list_room_memberships, 3) do
      persistence.list_room_memberships(state, room_id, opts)
    end
  end

  @doc false
  @spec revoke_membership(atom(), String.t(), keyword()) ::
          {:ok, RoomMembership.t()} | {:error, term()}
  def revoke_membership(runtime, membership_id, opts)
      when is_binary(membership_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_room_membership, 2),
         {:ok, membership} <- get_membership(runtime, membership_id) do
      ended_at = Keyword.get(opts, :ended_at, DateTime.utc_now())
      persistence.save_room_membership(state, RoomMembership.revoke(membership, ended_at))
    end
  end

  @doc false
  @spec route_thread(atom(), String.t(), String.t(), keyword()) ::
          {:ok, AgentThreadRoute.t()} | {:error, term()}
  def route_thread(runtime, thread_id, endpoint_id, opts)
      when is_binary(thread_id) and is_binary(endpoint_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_agent_thread_route, 2),
         :ok <- require_callback(persistence, :get_agent_thread_route, 2),
         {:ok, %Thread{status: :active} = thread} <- persistence.get_thread(state, thread_id),
         {:ok, %AgentMessagingEndpoint{status: :active} = endpoint} <- get_endpoint(runtime, endpoint_id),
         {:ok, %RoomMembership{status: :active}} <-
           get_membership_by_scope(persistence, state, thread.room_id, endpoint.id),
         {:ok, route} <- build_thread_route(persistence, state, thread, endpoint, opts) do
      save_thread_route(persistence, state, thread, endpoint, route, opts)
    else
      {:ok, %Thread{status: status}} -> {:error, {:thread_inactive, status}}
      {:ok, %AgentMessagingEndpoint{status: status}} -> {:error, {:endpoint_inactive, status}}
      {:ok, %RoomMembership{status: status}} -> {:error, {:membership_inactive, status}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec get_route(atom(), String.t()) :: {:ok, AgentThreadRoute.t()} | {:error, term()}
  def get_route(runtime, thread_id) when is_binary(thread_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_agent_thread_route, 2) do
      persistence.get_agent_thread_route(state, thread_id)
    end
  end

  @doc false
  @spec list_routes(atom(), String.t(), keyword()) ::
          {:ok, [AgentThreadRoute.t()]} | {:error, term()}
  def list_routes(runtime, endpoint_id, opts) when is_binary(endpoint_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :list_agent_thread_routes, 3) do
      persistence.list_agent_thread_routes(state, endpoint_id, opts)
    end
  end

  @doc false
  @spec put_route_correlations(atom(), String.t(), map()) ::
          {:ok, AgentThreadRoute.t()} | {:error, term()}
  def put_route_correlations(runtime, thread_id, correlations)
      when is_binary(thread_id) and is_map(correlations) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_agent_thread_route, 2),
         {:ok, %AgentThreadRoute{status: :active} = route} <- get_route(runtime, thread_id) do
      route = AgentThreadRoute.put_correlations(route, correlations)
      persistence.save_agent_thread_route(state, route)
    else
      {:ok, %AgentThreadRoute{status: status}} -> {:error, {:route_inactive, status}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec revoke_route(atom(), String.t(), keyword()) ::
          {:ok, AgentThreadRoute.t()} | {:error, term()}
  def revoke_route(runtime, thread_id, opts) when is_binary(thread_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_agent_thread_route, 2),
         {:ok, route} <- get_route(runtime, thread_id) do
      revoked_at = Keyword.get(opts, :revoked_at, DateTime.utc_now())
      persistence.save_agent_thread_route(state, AgentThreadRoute.revoke(route, revoked_at))
    end
  end

  @doc false
  @spec resolve_target(atom(), String.t()) :: {:ok, AgentEndpointTarget.t()} | {:error, term()}
  def resolve_target(runtime, thread_id) when is_binary(thread_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with {:ok, %Thread{status: :active} = thread} <- persistence.get_thread(state, thread_id),
         {:ok, %AgentThreadRoute{status: :active} = route} <- get_route(runtime, thread_id),
         :ok <- ensure_route_room(route, thread),
         {:ok, %AgentMessagingEndpoint{status: :active, availability: :available} = endpoint} <-
           get_endpoint(runtime, route.endpoint_id),
         {:ok, %RoomMembership{status: :active} = membership} <-
           get_membership_by_scope(persistence, state, thread.room_id, endpoint.id),
         {:ok, target} <- AgentEndpointTarget.new(endpoint, membership, route) do
      {:ok, target}
    else
      {:ok, %Thread{status: status}} ->
        {:error, {:thread_inactive, status}}

      {:ok, %AgentThreadRoute{status: status}} ->
        {:error, {:route_inactive, status}}

      {:ok, %AgentMessagingEndpoint{status: status}} when status != :active ->
        {:error, {:endpoint_inactive, status}}

      {:ok, %AgentMessagingEndpoint{availability: availability}} ->
        {:error, {:endpoint_unavailable, availability}}

      {:ok, %RoomMembership{status: status}} ->
        {:error, {:membership_inactive, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_agent_participant(persistence, state, principal_id) do
    case persistence.get_participant(state, principal_id) do
      {:ok, %Participant{type: :agent}} -> :ok
      {:ok, %Participant{type: type}} -> {:error, {:endpoint_principal_must_be_agent, type}}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_initial_endpoint(%AgentMessagingEndpoint{status: :active}), do: :ok
  defp ensure_initial_endpoint(%AgentMessagingEndpoint{status: status}), do: {:error, {:invalid_initial_status, status}}

  defp create_or_get_endpoint(persistence, state, endpoint) do
    jidoka_id = endpoint.jidoka_agent_ref["id"]

    case persistence.get_agent_messaging_endpoint_by_ref(state, jidoka_id) do
      {:ok, %{principal_id: principal_id} = existing} when principal_id == endpoint.principal_id ->
        {:ok, existing}

      {:ok, existing} ->
        {:error, {:jidoka_agent_ref_conflict, existing.id}}

      {:error, :not_found} ->
        case persistence.save_agent_messaging_endpoint(state, endpoint) do
          {:error, {kind, _id}} = error
          when kind in [:jidoka_agent_ref_conflict, :agent_endpoint_principal_conflict] ->
            resolve_endpoint_save_conflict(persistence, state, endpoint, error)

          result ->
            result
        end
    end
  end

  defp resolve_endpoint_save_conflict(persistence, state, endpoint, error) do
    case persistence.get_agent_messaging_endpoint_by_ref(state, endpoint.jidoka_agent_ref["id"]) do
      {:ok, %{principal_id: principal_id} = existing} when principal_id == endpoint.principal_id ->
        {:ok, existing}

      _other ->
        error
    end
  end

  defp get_or_build_membership(persistence, state, endpoint, room_id, opts) do
    case persistence.get_room_membership(state, room_id, endpoint.id) do
      {:ok, %RoomMembership{status: :active} = membership} ->
        {:ok, membership}

      {:ok, %RoomMembership{status: status}} ->
        {:error, {:membership_inactive, status}}

      {:error, :not_found} ->
        {:ok,
         RoomMembership.new(%{
           room_id: room_id,
           principal_id: endpoint.principal_id,
           endpoint_id: endpoint.id,
           metadata: Keyword.get(opts, :metadata, %{})
         })}
    end
  end

  defp save_or_get_membership(persistence, state, membership) do
    case persistence.save_room_membership(state, membership) do
      {:error, {:room_membership_conflict, _membership_id}} ->
        case persistence.get_room_membership(state, membership.room_id, membership.endpoint_id) do
          {:ok, %RoomMembership{status: :active} = existing} -> {:ok, existing}
          {:ok, %RoomMembership{status: status}} -> {:error, {:membership_inactive, status}}
          {:error, _reason} = error -> error
        end

      result ->
        result
    end
  end

  defp get_membership_by_scope(persistence, state, room_id, endpoint_id) do
    with :ok <- require_callback(persistence, :get_room_membership, 3) do
      persistence.get_room_membership(state, room_id, endpoint_id)
    end
  end

  defp build_thread_route(persistence, state, thread, endpoint, opts) do
    existing = persistence.get_agent_thread_route(state, thread.id)

    case existing do
      {:ok, route} ->
        same_endpoint? = route.endpoint_id == endpoint.id

        attrs =
          %{
            id: route.id,
            room_id: thread.room_id,
            thread_id: thread.id,
            endpoint_id: endpoint.id,
            status: :active,
            jidoka_session_ref: route_value(opts, :jidoka_session_ref, route, same_endpoint?),
            jidoka_request_ref: route_value(opts, :jidoka_request_ref, route, same_endpoint?),
            jidoka_turn_ref: route_value(opts, :jidoka_turn_ref, route, same_endpoint?),
            delivery_revision: route.delivery_revision + 1,
            metadata: Keyword.get(opts, :metadata, route.metadata),
            inserted_at: route.inserted_at,
            updated_at: DateTime.utc_now()
          }

        {:ok, AgentThreadRoute.new(attrs)}

      {:error, :not_found} ->
        attrs =
          %{
            room_id: thread.room_id,
            thread_id: thread.id,
            endpoint_id: endpoint.id,
            jidoka_session_ref: Keyword.get(opts, :jidoka_session_ref),
            jidoka_request_ref: Keyword.get(opts, :jidoka_request_ref),
            jidoka_turn_ref: Keyword.get(opts, :jidoka_turn_ref),
            metadata: Keyword.get(opts, :metadata, %{})
          }

        {:ok, AgentThreadRoute.new(attrs)}

      {:error, _reason} = error ->
        error
    end
  end

  defp save_thread_route(persistence, state, thread, endpoint, route, opts) do
    case persistence.save_agent_thread_route(state, route) do
      {:error, {:agent_thread_route_conflict, _route_id}} ->
        with {:ok, updated} <- build_thread_route(persistence, state, thread, endpoint, opts) do
          persistence.save_agent_thread_route(state, updated)
        end

      result ->
        result
    end
  end

  defp route_value(opts, key, route, true), do: Keyword.get(opts, key, Map.get(route, key))
  defp route_value(opts, key, _route, false), do: Keyword.get(opts, key)

  defp ensure_route_room(%AgentThreadRoute{room_id: room_id}, %Thread{room_id: room_id}), do: :ok
  defp ensure_route_room(_route, _thread), do: {:error, :thread_route_room_mismatch}

  defp require_callback(persistence, name, arity) do
    if function_exported?(persistence, name, arity), do: :ok, else: {:error, :unsupported}
  end
end
