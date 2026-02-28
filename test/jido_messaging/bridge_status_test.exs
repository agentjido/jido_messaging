defmodule Jido.Messaging.BridgeStatusTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{Incoming, WebhookRequest}
  alias Jido.Messaging.{InboundRouter, OutboundGateway}

  defmodule StatusAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(%{"kind" => "message"} = payload) do
      {:ok,
       Incoming.new(%{
         external_room_id: payload["room"],
         external_user_id: payload["user"],
         external_message_id: payload["id"],
         text: payload["text"],
         chat_type: :group,
         raw: payload
       })}
    end

    def transform_incoming(_payload), do: {:error, :unsupported_payload}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:ok, %{message_id: "ok"}}

    @impl true
    def verify_webhook(%WebhookRequest{}, opts) do
      if Keyword.get(opts, :reject_signature, false), do: {:error, :invalid_signature}, else: :ok
    end
  end

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    {:ok, _bridge} = TestMessaging.put_bridge_config(%{id: "bridge_status", adapter_module: StatusAdapter})

    :ok = wait_for_bridge(TestMessaging, "bridge_status")
    :ok
  end

  test "updates ingress and outbound timestamps" do
    assert {:ok, {:message, _message, _context, _event}} =
             InboundRouter.route_payload(
               TestMessaging,
               "bridge_status",
               %{"kind" => "message", "room" => "chat_1", "user" => "u1", "id" => "m1", "text" => "hello"}
             )

    assert {:ok, _} =
             OutboundGateway.send_message(
               TestMessaging,
               %{channel: StatusAdapter, bridge_id: "bridge_status", external_room_id: "chat_1"},
               "hello"
             )

    {:ok, status} = TestMessaging.bridge_status("bridge_status")
    assert not is_nil(status.last_ingress_at)
    assert not is_nil(status.last_outbound_at)
  end

  test "tracks last error" do
    assert {:error, :invalid_signature} =
             InboundRouter.route_webhook(
               TestMessaging,
               "bridge_status",
               %{"kind" => "message", "room" => "chat_1", "user" => "u1", "id" => "m1", "text" => "x"},
               reject_signature: true
             )

    {:ok, status} = TestMessaging.bridge_status("bridge_status")
    assert status.last_error == :invalid_signature
  end

  defp wait_for_bridge(instance_module, bridge_id, attempts \\ 20)

  defp wait_for_bridge(_instance_module, _bridge_id, 0), do: {:error, :bridge_not_started}

  defp wait_for_bridge(instance_module, bridge_id, attempts) do
    case instance_module.bridge_status(bridge_id) do
      {:ok, _status} ->
        :ok

      {:error, :not_found} ->
        Process.sleep(10)
        wait_for_bridge(instance_module, bridge_id, attempts - 1)
    end
  end
end
