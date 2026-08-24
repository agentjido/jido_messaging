defmodule Jido.Messaging.AgentDirectory do
  @moduledoc """
  Safe projection and discovery boundary for Jidoka agents.

  A Jidoka-owned adapter publishes redacted records with `project/2`. Queries
  require an `AgentDirectoryScope` that an application builds from current
  messaging membership and authorization results.
  """

  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    AgentDirectoryData,
    AgentDirectoryEntry,
    AgentDirectoryProjection,
    AgentDirectoryScope,
    Runtime
  }

  @query_keys [:id, :jidoka_agent_id, :name, :capability, :availability, :version, :verification_state, :invokable]
  @availabilities [:unknown, :available, :unavailable, :degraded]
  @verification_states [:unverified, :verified, :rejected]
  @max_limit 500

  @doc "Projects redacted Jidoka agent data into the messaging directory."
  @spec project(atom(), map()) :: {:ok, AgentDirectoryProjection.t()} | {:error, term()}
  def project(runtime, attrs) when is_atom(runtime) and is_map(attrs) do
    projection = AgentDirectoryProjection.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, save_agent_directory_projection: 2),
         {:ok, %Participant{} = participant} <- persistence.get_participant(state, projection.principal_id),
         :ok <- validate_agent_participant(participant),
         :ok <- validate_endpoint(persistence, state, projection) do
      persistence.save_agent_directory_projection(state, projection)
    end
  rescue
    ArgumentError -> {:error, :invalid_agent_directory_projection}
  end

  @doc "Projects safe data through a Jidoka-owned adapter callback."
  @spec project_from(atom(), module(), term(), map(), keyword()) ::
          {:ok, AgentDirectoryProjection.t()} | {:error, term()}
  def project_from(runtime, projector, source, context \\ %{}, opts \\ [])
      when is_atom(runtime) and is_atom(projector) and is_map(context) and is_list(opts) do
    if function_exported?(projector, :to_directory_projection, 3) do
      case call_projector(projector, source, context, opts) do
        {:ok, attrs} when is_map(attrs) -> project(runtime, attrs)
        {:ok, _invalid} -> {:error, :invalid_agent_directory_projector_result}
        {:error, _reason} = error -> error
        _invalid -> {:error, :invalid_agent_directory_projector_result}
      end
    else
      {:error, :invalid_agent_directory_projector}
    end
  end

  @doc "Gets a projected Jidoka agent by projection ID."
  @spec get(atom(), String.t()) :: {:ok, AgentDirectoryProjection.t()} | {:error, term()}
  def get(runtime, projection_id) when is_atom(runtime) and is_binary(projection_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, get_agent_directory_projection: 2) do
      persistence.get_agent_directory_projection(state, projection_id)
    end
  end

  @doc "Searches Jidoka agents within an explicit endpoint scope."
  @spec search(module(), atom(), map(), AgentDirectoryScope.t(), keyword()) ::
          {:ok, [AgentDirectoryEntry.t()]} | {:error, term()}
  def search(instance_module, runtime, query, scope, opts \\ [])
      when is_atom(instance_module) and is_atom(runtime) and is_map(query) and is_list(opts) do
    with :ok <- validate_scope(instance_module, scope),
         {persistence, state} <- Runtime.get_persistence(runtime),
         :ok <- require_callbacks(persistence, list_agent_directory_projections: 2),
         {:ok, projections} <-
           persistence.list_agent_directory_projections(state,
             endpoint_ids: Map.keys(scope.endpoint_principals),
             limit: @max_limit
           ) do
      filter_projections(projections, query, scope, opts)
    end
  end

  @doc "Looks up one Jidoka agent within an explicit endpoint scope."
  @spec lookup(module(), atom(), map(), AgentDirectoryScope.t(), keyword()) ::
          {:ok, AgentDirectoryEntry.t()} | {:error, term()}
  def lookup(instance_module, runtime, query, scope, opts \\ []) do
    case search(instance_module, runtime, query, scope, opts) do
      {:ok, [entry]} -> {:ok, entry}
      {:ok, []} -> {:error, :not_found}
      {:ok, entries} -> {:error, {:ambiguous, entries}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec search_from_directory(atom(), map(), keyword()) :: {:ok, [AgentDirectoryEntry.t()]} | {:error, term()}
  def search_from_directory(runtime, query, opts) when is_atom(runtime) and is_map(query) and is_list(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, %AgentDirectoryScope{} = scope} ->
        %Runtime{instance_module: instance_module} = Runtime.get_state(runtime)
        search(instance_module, runtime, query, scope, Keyword.delete(opts, :scope))

      _other ->
        {:error, :agent_directory_scope_required}
    end
  end

  @doc false
  @spec lookup_from_directory(atom(), map(), keyword()) :: {:ok, AgentDirectoryEntry.t()} | {:error, term()}
  def lookup_from_directory(runtime, query, opts) when is_atom(runtime) and is_map(query) and is_list(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, %AgentDirectoryScope{} = scope} ->
        %Runtime{instance_module: instance_module} = Runtime.get_state(runtime)
        lookup(instance_module, runtime, query, scope, Keyword.delete(opts, :scope))

      _other ->
        {:error, :agent_directory_scope_required}
    end
  end

  @doc false
  @spec filter_projections([AgentDirectoryProjection.t()], map(), AgentDirectoryScope.t(), keyword()) ::
          {:ok, [AgentDirectoryEntry.t()]} | {:error, term()}
  def filter_projections(projections, query, %AgentDirectoryScope{} = scope, opts)
      when is_list(projections) and is_map(query) and is_list(opts) do
    with :ok <- validate_query(query),
         {:ok, limit} <- validate_limit(Keyword.get(opts, :limit, 100)) do
      now = DateTime.utc_now()

      entries =
        projections
        |> Enum.filter(&visible_to_scope?(&1, scope))
        |> Enum.map(&AgentDirectoryEntry.new(&1, now))
        |> Enum.filter(&matches?(&1, query))
        |> Enum.sort_by(& &1.id)
        |> Enum.take(limit)

      {:ok, entries}
    end
  end

  defp visible_to_scope?(%AgentDirectoryProjection{listing_state: :listed, endpoint_ref: endpoint} = projection, scope)
       when not is_nil(endpoint) do
    projection.verification_state != :rejected and
      AgentDirectoryScope.permits?(scope, endpoint.id, projection.principal_id)
  end

  defp visible_to_scope?(_projection, _scope), do: false

  defp matches?(entry, query) do
    equals?(entry.id, AgentDirectoryData.value(query, :id)) and
      equals?(entry.jidoka_agent_ref["id"], AgentDirectoryData.value(query, :jidoka_agent_id)) and
      contains?(entry.name, AgentDirectoryData.value(query, :name)) and
      capability_matches?(entry.capabilities, AgentDirectoryData.value(query, :capability)) and
      equals?(entry.availability, AgentDirectoryData.value(query, :availability)) and
      equals?(entry.version, AgentDirectoryData.value(query, :version)) and
      equals?(entry.verification_state, AgentDirectoryData.value(query, :verification_state)) and
      equals?(entry.invokable, AgentDirectoryData.value(query, :invokable))
  end

  defp equals?(_actual, nil), do: true
  defp equals?(actual, expected) when is_atom(actual), do: Atom.to_string(actual) == to_string(expected)
  defp equals?(actual, expected), do: actual == expected

  defp contains?(_actual, nil), do: true

  defp contains?(actual, expected) when is_binary(actual) and is_binary(expected) do
    String.contains?(String.downcase(actual), String.downcase(String.trim(expected)))
  end

  defp contains?(_actual, _expected), do: false

  defp capability_matches?(_capabilities, nil), do: true

  defp capability_matches?(capabilities, expected) when is_binary(expected) do
    String.downcase(String.trim(expected)) in capabilities
  end

  defp capability_matches?(_capabilities, _expected), do: false

  defp validate_query(query) do
    try do
      :ok = AgentDirectoryData.strict_keys!(query, @query_keys, "agent directory query")
      validate_query_values(query)
    rescue
      ArgumentError -> {:error, :invalid_agent_directory_query}
    end
  end

  defp validate_query_values(query) do
    Enum.each([:id, :jidoka_agent_id, :name, :capability, :version], fn key ->
      case AgentDirectoryData.value(query, key) do
        nil -> :ok
        value when is_binary(value) and byte_size(value) <= 512 -> :ok
        _value -> raise ArgumentError, "invalid agent directory query value"
      end
    end)

    case AgentDirectoryData.value(query, :invokable) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _value -> raise ArgumentError, "invalid invokable query"
    end

    validate_query_enum(query, :availability, @availabilities)
    validate_query_enum(query, :verification_state, @verification_states)

    :ok
  end

  defp validate_query_enum(query, key, allowed) do
    case AgentDirectoryData.value(query, key) do
      nil -> :ok
      value -> AgentDirectoryData.enum!(value, allowed, key)
    end
  end

  defp validate_scope(instance_module, %AgentDirectoryScope{instance_module: instance_module}), do: :ok

  defp validate_scope(_instance_module, %AgentDirectoryScope{}),
    do: {:error, :agent_directory_scope_instance_mismatch}

  defp validate_scope(_instance_module, _scope), do: {:error, :agent_directory_scope_required}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, min(limit, @max_limit)}
  defp validate_limit(_limit), do: {:error, :invalid_agent_directory_limit}

  defp validate_agent_participant(%Participant{type: :agent}), do: :ok
  defp validate_agent_participant(%Participant{}), do: {:error, :agent_directory_principal_must_be_agent}

  defp validate_endpoint(_persistence, _state, %AgentDirectoryProjection{listing_state: :withdrawn}), do: :ok
  defp validate_endpoint(_persistence, _state, %AgentDirectoryProjection{endpoint_ref: nil}), do: :ok

  defp validate_endpoint(persistence, state, projection) do
    if function_exported?(persistence, :get_agent_messaging_endpoint, 2) do
      case persistence.get_agent_messaging_endpoint(state, projection.endpoint_ref.id) do
        {:ok, %{principal_id: principal_id, status: :active}} when principal_id == projection.principal_id ->
          :ok

        {:ok, %{principal_id: principal_id}} when principal_id != projection.principal_id ->
          {:error, :agent_directory_endpoint_principal_mismatch}

        {:ok, %{status: status}} ->
          {:error, {:agent_directory_endpoint_inactive, status}}

        {:error, :not_found} ->
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  end

  defp call_projector(projector, source, context, opts) do
    projector.to_directory_projection(source, context, opts)
  rescue
    _exception -> {:error, :agent_directory_projector_failed}
  catch
    _kind, _reason -> {:error, :agent_directory_projector_failed}
  end

  defp require_callbacks(persistence, callbacks) do
    if Enum.all?(callbacks, fn {name, arity} -> function_exported?(persistence, name, arity) end),
      do: :ok,
      else: {:error, :unsupported}
  end
end
