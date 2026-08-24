defmodule Jido.Messaging.AgentDirectoryScope do
  @moduledoc """
  Explicit authorization scope for Jidoka agent directory queries.

  Each map entry binds one endpoint ID to the principal ID that the caller can
  discover. The application must build this scope from current room
  membership and authorization results. User input is not a trusted scope.
  """

  alias Jido.Messaging.AgentDirectoryData

  @max_bindings 500

  @enforce_keys [:instance_module, :endpoint_principals]
  defstruct [:instance_module, :endpoint_principals, metadata: %{}]

  @type t :: %__MODULE__{
          instance_module: module(),
          endpoint_principals: %{optional(String.t()) => String.t()},
          metadata: map()
        }

  @doc "Builds a directory scope from authorized endpoint and principal pairs."
  @spec new(module(), map(), map()) :: {:ok, t()} | {:error, :invalid_agent_directory_scope}
  def new(instance_module, endpoint_principals, metadata \\ %{})

  def new(instance_module, endpoint_principals, metadata)
      when is_atom(instance_module) and is_map(endpoint_principals) and not is_struct(endpoint_principals) and
             is_map(metadata) and not is_struct(metadata) and map_size(endpoint_principals) <= @max_bindings do
    try do
      normalized =
        Map.new(endpoint_principals, fn {endpoint_id, principal_id} ->
          {
            AgentDirectoryData.required_ref!(endpoint_id, :endpoint_id),
            AgentDirectoryData.required_ref!(principal_id, :principal_id)
          }
        end)

      {:ok, %__MODULE__{instance_module: instance_module, endpoint_principals: normalized, metadata: metadata}}
    rescue
      ArgumentError -> {:error, :invalid_agent_directory_scope}
    end
  end

  def new(_instance_module, _endpoint_principals, _metadata), do: {:error, :invalid_agent_directory_scope}

  @doc "Builds a directory scope and raises for invalid input."
  @spec new!(module(), map(), map()) :: t()
  def new!(instance_module, endpoint_principals, metadata \\ %{}) do
    case new(instance_module, endpoint_principals, metadata) do
      {:ok, scope} -> scope
      {:error, :invalid_agent_directory_scope} -> raise ArgumentError, "invalid agent directory scope"
    end
  end

  @doc false
  @spec permits?(t(), String.t(), String.t()) :: boolean()
  def permits?(%__MODULE__{} = scope, endpoint_id, principal_id) do
    Map.get(scope.endpoint_principals, endpoint_id) == principal_id
  end
end
