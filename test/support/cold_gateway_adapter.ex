defmodule Jido.Messaging.Test.ColdGatewayAdapter do
  @moduledoc false
  use Jido.Chat.Adapter
  alias Jido.Chat.AdapterTestKit.MockTransport

  @impl true
  def channel_type, do: :cold_gateway
  @impl true
  def signal_protocol, do: 1
  @impl true
  def configure_binding(opts), do: {:ok, opts}
  @impl true
  def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
  @impl true
  def capabilities, do: %{send_message: :native}
  @impl true
  def send_message(room, text, opts) do
    MockTransport.request(opts[:transport], :send_message, %{room_id: room, text: text}, {:ok, %{id: "cold-sent"}})
  end
end
