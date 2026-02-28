defmodule Jido.Messaging.BridgeListenerIngressTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{EventEnvelope, Incoming, WebhookRequest}

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
         mode: Keyword.get(opts, :mode, :payload),
         test_pid: Keyword.get(opts, :test_pid),
         secret: Keyword.get(opts, :secret, "listener-secret")
       }}
    end

    @impl true
    def handle_info(:emit_once, state) do
      emit_opts =
        case state.mode do
          :webhook ->
            [
              mode: :webhook,
              headers: %{"x-listener-secret" => state.secret},
              secret: state.secret,
              path: "/listener/webhook",
              method: "POST",
              raw_body: Jason.encode!(state.payload)
            ]

          _ ->
            [mode: :payload, path: "/listener/payload", method: "PAYLOAD"]
        end

      result = invoke_sink(state.sink_mfa, state.payload, emit_opts)

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
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "ok"}}

    @impl true
    def verify_webhook(%WebhookRequest{} = request, opts) do
      expected = Keyword.get(opts, :secret, "listener-secret")
      if request.headers["x-listener-secret"] == expected, do: :ok, else: {:error, :invalid_signature}
    end

    @impl true
    def parse_event(%WebhookRequest{payload: payload}, _opts) do
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
           metadata: %{source: :listener}
         })}
      end
    end

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
    use Jido.Messaging, adapter: Jido.Messaging.Adapters.ETS
  end

  setup do
    start_supervised!(ListenerMessaging)
    :ok
  end

  test "bridge listener payload mode routes through ingress sink and ingests message" do
    {:ok, _config} =
      ListenerMessaging.put_bridge_config(%{
        id: "bridge_payload_listener",
        adapter_module: ListenerIngressAdapter,
        opts: %{
          ingress: %{mode: "polling"},
          test_pid: self()
        }
      })

    assert_receive {:listener_sink_result, :payload, {:ok, {:message, message, context, event}}}, 1_500
    assert message.external_id == "msg_bridge_payload_listener"
    assert context.bridge_id == "bridge_payload_listener"
    assert event.event_type == :message
  end

  test "bridge listener webhook mode routes through webhook request path" do
    {:ok, _config} =
      ListenerMessaging.put_bridge_config(%{
        id: "bridge_webhook_listener",
        adapter_module: ListenerIngressAdapter,
        opts: %{
          ingress: %{mode: "webhook"},
          test_pid: self()
        }
      })

    assert_receive {:listener_sink_result, :webhook, {:ok, {:message, message, context, event}}}, 1_500
    assert message.external_id == "msg_bridge_webhook_listener"
    assert context.bridge_id == "bridge_webhook_listener"
    assert event.event_type == :message
  end
end
