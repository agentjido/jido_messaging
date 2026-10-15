defmodule Jido.Messaging.BridgeListenerIngressTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.Factories, WebhookRequest}

  defmodule ListenerEmitWorker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      send(self(), :emit_once)

      {:ok,
       %{
         sink_mfa: Keyword.fetch!(opts, :sink_mfa),
         payload: Keyword.fetch!(opts, :payload),
         binding: Keyword.fetch!(opts, :binding),
         mode: Keyword.get(opts, :mode, :payload),
         test_pid: Keyword.get(opts, :test_pid),
         secret: Keyword.get(opts, :secret, "listener-secret")
       }}
    end

    @impl true
    def handle_info(:emit_once, state) do
      input =
        if state.mode == :webhook do
          WebhookRequest.new(%{
            payload: state.payload,
            headers: %{"x-listener-secret" => state.secret},
            method: "POST",
            path: "/listener/webhook"
          })
        else
          state.payload
        end

      verified =
        if state.mode == :webhook do
          state.binding.adapter.verify_webhook(input, state.binding.options)
        else
          :ok
        end

      result =
        with :ok <- verified,
             {:ok, delivery} <- Jido.Chat.normalize_event(state.binding, input) do
          invoke_sink(state.sink_mfa, delivery, [])
        end

      if is_pid(state.test_pid) do
        send(state.test_pid, {:listener_sink_result, state.mode, result})
      end

      {:noreply, state}
    end

    defp invoke_sink({module, function, args}, payload, opts) do
      apply(module, function, args ++ [payload, opts])
    end
  end

  defmodule ListenerIngressAdapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :telegram
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "ok"}}
    @impl true
    def verify_webhook(%WebhookRequest{} = request, opts) do
      expected = Keyword.get(opts, :secret, "listener-secret")
      if request.headers["x-listener-secret"] == expected, do: :ok, else: {:error, :invalid_signature}
    end

    @impl true
    def normalize_event(binding, %WebhookRequest{payload: payload}), do: normalize_event(binding, payload)

    def normalize_event(binding, %{"kind" => "message"} = payload) do
      fact =
        Factories.message_received(binding, %{
          "delivery_id" => payload["id"],
          "item_id" => payload["id"],
          "message_id" => payload["id"],
          "room_id" => payload["room"],
          "sender" => %{"id" => payload["user"]},
          "text" => payload["text"],
          "conversation_kind" => "group"
        })

      Jido.Chat.Delivery.new(binding, payload["id"], [fact])
    end

    def normalize_event(_binding, _payload), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)

    @impl true
    def listener_child_specs(bridge_id, opts) do
      ingress = Keyword.fetch!(opts, :ingress)
      sink_mfa = Keyword.fetch!(opts, :sink_mfa)
      settings = Keyword.fetch!(opts, :settings)

      mode =
        case ingress[:mode] || ingress["mode"] do
          "webhook" -> :webhook
          :webhook -> :webhook
          _ -> :payload
        end

      payload = %{
        "kind" => "message",
        "room" => "room_#{bridge_id}",
        "user" => "user_#{bridge_id}",
        "id" => "msg_#{bridge_id}",
        "text" => "listener hello #{bridge_id}"
      }

      {:ok,
       [
         Supervisor.child_spec(
           {ListenerEmitWorker,
            [
              sink_mfa: sink_mfa,
              binding: Keyword.fetch!(opts, :binding),
              mode: mode,
              payload: payload,
              secret: "listener-secret",
              test_pid: settings[:test_pid] || settings["test_pid"]
            ]},
           id: {:listener_emit_worker, bridge_id}
         )
       ]}
    end
  end

  defmodule ListenerMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(ListenerMessaging)
    :ok
  end

  test "polling listener normalizes a complete delivery before the sink" do
    {:ok, _config} =
      ListenerMessaging.put_bridge_config(%{
        id: "bridge_payload_listener",
        adapter_module: ListenerIngressAdapter,
        opts: %{
          ingress: %{mode: "polling"},
          test_pid: self()
        }
      })

    assert_receive {:listener_sink_result, :payload, {:ok, [fact]}}, 1_500
    assert fact.type == "jido.messaging.message.received"
    assert fact.data["bridge_id"] == "bridge_payload_listener"
    assert {:ok, message} = ListenerMessaging.get_message(fact.data["message_id"])
    assert message.external_id == "msg_bridge_payload_listener"
    assert Jido.Signal.Context.get(fact, "causationid") != nil
  end

  test "webhook listener verifies and normalizes before the sink" do
    {:ok, _config} =
      ListenerMessaging.put_bridge_config(%{
        id: "bridge_webhook_listener",
        adapter_module: ListenerIngressAdapter,
        opts: %{
          ingress: %{mode: "webhook"},
          test_pid: self()
        }
      })

    assert_receive {:listener_sink_result, :webhook, {:ok, [fact]}}, 1_500
    assert fact.type == "jido.messaging.message.received"
    assert fact.data["bridge_id"] == "bridge_webhook_listener"
    assert {:ok, message} = ListenerMessaging.get_message(fact.data["message_id"])
    assert message.external_id == "msg_bridge_webhook_listener"
    assert Jido.Signal.Context.get(fact, "causationid") != nil
  end
end
