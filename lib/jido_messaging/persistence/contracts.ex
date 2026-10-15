defmodule Jido.Messaging.Persistence.Contracts do
  @moduledoc false

  @groups [
    Jido.Messaging.Persistence.Contracts.Lifecycle,
    Jido.Messaging.Persistence.Contracts.Transactions,
    Jido.Messaging.Persistence.Contracts.Records,
    Jido.Messaging.Persistence.Contracts.ProviderBindings,
    Jido.Messaging.Persistence.Contracts.ControlPlane,
    Jido.Messaging.Persistence.Contracts.Authorization,
    Jido.Messaging.Persistence.Contracts.ExternalIdentity,
    Jido.Messaging.Persistence.Contracts.AgentRouting,
    Jido.Messaging.Persistence.Contracts.AgentDirectory,
    Jido.Messaging.Persistence.Contracts.Credentials,
    Jido.Messaging.Persistence.Contracts.Continuity,
    Jido.Messaging.Persistence.Contracts.TrustEvidence,
    Jido.Messaging.Persistence.Contracts.Activity
  ]

  @doc "Lists the storage feature contracts."
  @spec all() :: [module()]
  def all, do: @groups

  @doc "Lists feature contracts explicitly declared by an adapter."
  @spec declared(module()) :: [module()]
  def declared(adapter) do
    adapter
    |> apply(:__info__, [:attributes])
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.filter(&(&1 in @groups))
  end

  @doc "Lists callbacks missing from a feature implementation."
  @spec missing_callbacks(module(), module()) :: [{atom(), non_neg_integer()}]
  def missing_callbacks(adapter, contract) do
    Code.ensure_loaded!(adapter)
    Code.ensure_loaded!(contract)

    contract.behaviour_info(:callbacks)
    |> Enum.reject(fn {name, arity} -> function_exported?(adapter, name, arity) end)
    |> Enum.sort()
  end
end
