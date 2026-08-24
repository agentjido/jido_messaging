defmodule Jido.Messaging.AgentEndpointProvider do
  @moduledoc """
  Callback boundary implemented by a Jidoka-owned integration.

  Jido Messaging passes a bounded delivery envelope. The provider owns Jidoka
  agent lookup, process hosting, sessions, execution, and runtime errors. A
  provider must treat the delivery ID as an idempotency key.

  Core does not configure or call a provider automatically. An integration
  must first apply messaging authorization, resolve an endpoint target, and
  then call `Jido.Messaging.AgentEndpointDelivery.deliver/4`.
  """

  alias Jido.Messaging.AgentEndpointDelivery

  @type result ::
          :ok
          | {:ok, map()}
          | {:error, term()}

  @doc "Delivers one authorized messaging envelope to Jidoka."
  @callback deliver(AgentEndpointDelivery.t(), keyword()) :: result()
end
