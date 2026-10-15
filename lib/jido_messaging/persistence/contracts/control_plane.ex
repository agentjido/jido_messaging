defmodule Jido.Messaging.Persistence.Contracts.ControlPlane do
  @moduledoc """
  Storage contract for control plane.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.BridgeConfig
  alias Jido.Messaging.IngressSubscription
  alias Jido.Messaging.RoutingPolicy

  @type state :: Jido.Messaging.Persistence.state()
  @type bridge_id :: Jido.Messaging.Persistence.bridge_id()

  @callback save_bridge_config(state, BridgeConfig.t()) :: {:ok, BridgeConfig.t()} | {:error, term()}

  @callback get_bridge_config(state, String.t()) :: {:ok, BridgeConfig.t()} | {:error, :not_found}

  @callback list_bridge_configs(state, keyword()) :: {:ok, [BridgeConfig.t()]}

  @callback delete_bridge_config(state, String.t()) :: :ok | {:error, :not_found}

  @callback save_ingress_subscription(state, IngressSubscription.t()) ::
              {:ok, IngressSubscription.t()} | {:error, term()}

  @callback list_ingress_subscriptions(state, bridge_id(), keyword()) :: {:ok, [IngressSubscription.t()]}

  @callback delete_ingress_subscription(state, bridge_id(), String.t()) :: :ok | {:error, :not_found}

  @callback save_routing_policy(state, RoutingPolicy.t()) :: {:ok, RoutingPolicy.t()} | {:error, term()}

  @callback get_routing_policy(state, String.t()) :: {:ok, RoutingPolicy.t()} | {:error, :not_found}

  @callback delete_routing_policy(state, String.t()) :: :ok | {:error, :not_found}
end
