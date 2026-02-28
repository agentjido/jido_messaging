defmodule Jido.Messaging.InboundRouterTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{EventEnvelope, Incoming, WebhookRequest}
  alias Jido.Messaging.InboundRouter

  defmodule RouterAdapter do
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
         username: payload["user_name"],
         display_name: payload["display_name"],
         chat_type: :group,
         raw: payload
       })}
    end

    def transform_incoming(_payload), do: {:error, :unsupported_payload}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}

    @impl true
    def verify_webhook(%WebhookRequest{}, opts) do
      if Keyword.get(opts, :reject_signature, false) do
        {:error, :invalid_signature}
      else
        :ok
      end
    end

    @impl true
    def parse_event(%WebhookRequest{payload: %{"kind" => "noop"}}, _opts), do: {:ok, :noop}

    def parse_event(%WebhookRequest{payload: %{"kind" => "reaction"} = payload}, _opts) do
      {:ok,
       EventEnvelope.new(%{
         adapter_name: :telegram,
         event_type: :reaction,
         thread_id: "telegram:#{payload["room"]}",
         channel_id: payload["room"],
         message_id: payload["id"],
         payload: %{emoji: payload["emoji"], room: payload["room"]},
         raw: payload,
         metadata: %{source: :webhook}
       })}
    end

    def parse_event(%WebhookRequest{payload: payload}, _opts) do
      with {:ok, incoming} <- transform_incoming(payload) do
        {:ok,
         EventEnvelope.new(%{
           adapter_name: :telegram,
           event_type: :message,
           thread_id: "telegram:#{payload["room"]}",
           channel_id: payload["room"],
           message_id: payload["id"],
           payload: incoming,
           raw: payload,
           metadata: %{source: :webhook}
         })}
      end
    end
  end

  defmodule TestMessaging do
    use Jido.Messaging,
      adapter: Jido.Messaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    {:ok, _bridge} = TestMessaging.put_bridge_config(%{id: "bridge_tg", adapter_module: RouterAdapter})
    :ok
  end

  describe "route_payload/4" do
    test "routes message payloads into ingest and returns message/context/event" do
      payload = %{
        "kind" => "message",
        "room" => "chat_42",
        "user" => "user_7",
        "id" => "msg_100",
        "text" => "hello from payload",
        "user_name" => "alice",
        "display_name" => "Alice"
      }

      assert {:ok, {:message, message, context, event}} =
               InboundRouter.route_payload(TestMessaging, "bridge_tg", payload)

      assert message.external_id == "msg_100"
      assert context.external_room_id == "chat_42"
      assert context.bridge_id == "bridge_tg"
      assert event.event_type == :message
    end

    test "returns duplicate marker on repeated payload id in same room" do
      payload = %{
        "kind" => "message",
        "room" => "chat_dup",
        "user" => "user_dup",
        "id" => "msg_dup",
        "text" => "dup"
      }

      assert {:ok, {:message, _message, _context, _event}} =
               InboundRouter.route_payload(TestMessaging, "bridge_tg", payload)

      assert {:ok, {:duplicate, _event}} =
               InboundRouter.route_payload(TestMessaging, "bridge_tg", payload)
    end
  end

  describe "route_webhook/4" do
    test "returns :noop for ack-only webhook events" do
      assert {:ok, :noop} =
               InboundRouter.route_webhook(
                 TestMessaging,
                 "bridge_tg",
                 %{"kind" => "noop"},
                 headers: %{"x-test" => "1"}
               )
    end

    test "returns typed non-message event without ingesting" do
      assert {:ok, {:event, event}} =
               InboundRouter.route_webhook(
                 TestMessaging,
                 "bridge_tg",
                 %{"kind" => "reaction", "room" => "chat_1", "id" => "msg_1", "emoji" => "👍"}
               )

      assert event.event_type == :reaction
      assert event.payload.emoji == "👍"
    end

    test "returns webhook verification errors" do
      assert {:error, :invalid_signature} =
               InboundRouter.route_webhook(
                 TestMessaging,
                 "bridge_tg",
                 %{"kind" => "message", "room" => "chat_1", "user" => "u1", "id" => "m1", "text" => "x"},
                 reject_signature: true
               )
    end

    test "returns :bridge_not_found for unknown bridge id" do
      assert {:error, :bridge_not_found} =
               InboundRouter.route_webhook(
                 TestMessaging,
                 "missing_bridge",
                 %{"kind" => "noop"}
               )
    end

    test "returns :bridge_disabled for disabled bridge config" do
      {:ok, _bridge} =
        TestMessaging.put_bridge_config(%{
          id: "bridge_disabled",
          adapter_module: RouterAdapter,
          enabled: false
        })

      assert {:error, :bridge_disabled} =
               InboundRouter.route_payload(
                 TestMessaging,
                 "bridge_disabled",
                 %{"kind" => "message", "room" => "chat_1", "user" => "u1", "id" => "m1", "text" => "x"}
               )
    end
  end
end
