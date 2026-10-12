defmodule Jido.Messaging.IngressSink do
  @moduledoc "Private listener sink for complete normalized Chat deliveries."
  alias Jido.Chat.{Delivery, Signal.Policy}
  alias Jido.Messaging.Runtime

  @doc false
  @spec emit(module(), String.t(), Delivery.t(), keyword()) :: {:ok, [Jido.Signal.t()]} | {:error, term()}
  def emit(instance, bridge, delivery, opts \\ [])

  def emit(instance, bridge, %Delivery{} = delivery, _opts) do
    with {:ok, binding} <- Runtime.binding(instance.__jido_messaging__(:runtime), bridge),
         {:ok, delivery} <- Delivery.validate(binding, delivery) do
      case Jido.Messaging.accept_delivery(instance, delivery) do
        {:ok, _} = accepted ->
          Jido.Messaging.BridgeServer.mark_ingress(instance, bridge)
          accepted

        {:error, reason} = error ->
          Jido.Messaging.BridgeServer.mark_error(instance, bridge, reason)
          error
      end
    end
  end

  def emit(_instance, _bridge, _payload, _opts), do: Policy.error(:invalid_delivery)
end
