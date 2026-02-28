defmodule Jido.Messaging.IngressSinkTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{EventEnvelope, Incoming, WebhookRequest}
  alias Jido.Messaging.IngressSink

  defmodule SinkAdapter do
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
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "msg"}}

    @impl true
    def verify_webhook(%WebhookRequest{} = request, opts) do
      expected = Keyword.get(opts, :secret, "ok")
      if request.headers["x-test-secret"] == expected, do: :ok, else: {:error, :invalid_signature}
    end

    @impl true
    def parse_event(%WebhookRequest{} = request, _opts) do
      send(self(), {:parse_event_request, request.path, request.method, request.headers})

      case request.payload do
        %{"kind" => "noop"} ->
          {:ok, :noop}

        payload ->
          with {:ok, incoming} <- transform_incoming(payload) do
            {:ok,
             EventEnvelope.new(%{
               adapter_name: :telegram,
               event_type: :message,
               thread_id: "telegram:#{incoming.external_room_id}",
               channel_id: to_string(incoming.external_room_id),
               message_id: to_string(incoming.external_message_id),
               payload: incoming,
               raw: payload,
               metadata: %{source: :webhook}
             })}
          end
      end
    end
  end

  defmodule SinkMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(SinkMessaging)

    {:ok, _bridge} =
      SinkMessaging.put_bridge_config(%{
        id: "bridge_sink",
        adapter_module: SinkAdapter,
        enabled: true
      })

    {:ok, _bridge} =
      SinkMessaging.put_bridge_config(%{
        id: "bridge_sink_b",
        adapter_module: SinkAdapter,
        enabled: true
      })

    :ok
  end

  test "emit/4 routes webhook payload by default and preserves request metadata" do
    outcome =
      IngressSink.emit(
        SinkMessaging,
        "bridge_sink",
        %{"kind" => "noop"},
        headers: %{"x-test-secret" => "sekret"},
        path: "/webhooks/test",
        method: "POST",
        raw_body: ~s({"kind":"noop"}),
        secret: "sekret"
      )

    assert {:ok, :noop} = outcome

    assert_receive {:parse_event_request, "/webhooks/test", "POST", headers}, 200
    assert headers["x-test-secret"] == "sekret"
  end

  test "emit/4 routes payload mode to route_payload and ingests message events" do
    payload = %{
      "kind" => "message",
      "room" => "chat_1",
      "user" => "u_1",
      "id" => "msg_1",
      "text" => "hello from payload sink"
    }

    assert {:ok, {:message, message, context, event}} =
             IngressSink.emit(SinkMessaging, "bridge_sink", payload, mode: :payload)

    assert message.external_id == "msg_1"
    assert context.bridge_id == "bridge_sink"
    assert event.event_type == :message
  end

  test "bridge-scoped dedupe remains isolated across bridge ids" do
    payload = %{
      "kind" => "message",
      "room" => "chat_shared",
      "user" => "u_shared",
      "id" => "msg_shared",
      "text" => "same external id"
    }

    assert {:ok, {:message, _message_a, context_a, _event_a}} =
             IngressSink.emit(SinkMessaging, "bridge_sink", payload, mode: :payload)

    assert {:ok, {:message, _message_b, context_b, _event_b}} =
             IngressSink.emit(SinkMessaging, "bridge_sink_b", payload, mode: :payload)

    assert context_a.bridge_id == "bridge_sink"
    assert context_b.bridge_id == "bridge_sink_b"

    assert {:ok, {:duplicate, _event}} =
             IngressSink.emit(SinkMessaging, "bridge_sink", payload, mode: :payload)
  end
end
