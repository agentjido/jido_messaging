defmodule Jido.Messaging.InboundRouterTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.{AdapterTestKit.Factories, Signal.Identity, WebhookRequest, WebhookResponse}
  alias Jido.Messaging.InboundRouter

  defmodule RouterAdapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :telegram
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts) do
      settings = opts[:settings] || %{}

      {:ok,
       opts
       |> Keyword.put(:reject_signature, settings[:reject_signature] || false)
       |> Keyword.put(:force_format_error, settings[:force_format_error] || false)}
    end

    @impl true
    def verify_webhook(%WebhookRequest{}, opts) do
      if opts[:reject_signature], do: {:error, :invalid_signature}, else: :ok
    end

    @impl true
    def normalize_event(binding, %WebhookRequest{payload: payload}), do: normalize_event(binding, payload)
    def normalize_event(binding, %{"kind" => "noop"}), do: Jido.Chat.Delivery.new(binding, "noop", [])

    def normalize_event(binding, %{"kind" => "message"} = payload) do
      sender = %{"id" => payload["user"]}
      sender = if payload["user_name"], do: Map.put(sender, "username", payload["user_name"]), else: sender
      sender = if payload["display_name"], do: Map.put(sender, "display_name", payload["display_name"]), else: sender

      fact =
        Factories.message_received(binding, %{
          "delivery_id" => payload["id"],
          "item_id" => payload["id"],
          "room_id" => payload["room"],
          "message_id" => payload["id"],
          "text" => payload["text"],
          "sender" => sender,
          "conversation_kind" => "group"
        })

      Jido.Chat.Delivery.new(binding, payload["id"], [fact])
    end

    def normalize_event(binding, %{"kind" => "reaction"} = payload) do
      fact =
        Jido.Chat.Signal.ReactionAdded.new!(
          %{
            "delivery_id" => payload["id"],
            "item_id" => payload["id"],
            "room_id" => payload["room"],
            "message_id" => payload["id"],
            "actor_id" => "actor",
            "reaction" => payload["emoji"]
          },
          source: binding.source,
          subject: Identity.conversation_subject(binding.id, payload["room"])
        )

      Jido.Chat.Delivery.new(binding, payload["id"], [fact])
    end

    def normalize_event(_binding, _payload), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    @impl true
    def format_webhook_response(_result, opts) do
      if opts[:force_format_error], do: {:error, :format_failed}, else: {:ok, WebhookResponse.accepted(%{ok: true})}
    end
  end

  defmodule ConfigAwareAdapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :config_aware
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def verify_webhook(request, opts) do
      if request.headers["authorization"] == opts[:credentials].token, do: :ok, else: {:error, :invalid_signature}
    end

    @impl true
    def normalize_event(binding, %WebhookRequest{}) do
      if binding.options[:settings][:parse_result] == :noop,
        do: Jido.Chat.Delivery.new(binding, "noop", []),
        else: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    end
  end

  defmodule BridgeSecretResolver do
    @behaviour Jido.Messaging.SecretResolver
    @impl true
    def resolve(:bridge_secret, _context), do: {:ok, "bridge-secret"}
  end

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    previous = Application.get_env(TestMessaging, :secret_resolver)
    Application.put_env(TestMessaging, :secret_resolver, BridgeSecretResolver)

    on_exit(fn ->
      if previous,
        do: Application.put_env(TestMessaging, :secret_resolver, previous),
        else: Application.delete_env(TestMessaging, :secret_resolver)
    end)

    start_supervised!(TestMessaging)
    {:ok, _} = TestMessaging.put_bridge_config(%{id: "bridge_tg", adapter_module: RouterAdapter})
    :ok
  end

  defp message do
    %{
      "kind" => "message",
      "room" => "chat_42",
      "user" => "user_7",
      "id" => "msg_100",
      "text" => "hello from payload",
      "user_name" => "alice",
      "display_name" => "Alice"
    }
  end

  test "the private payload control returns typed canonical acceptance facts" do
    assert {:ok, [fact]} = InboundRouter.route_payload(TestMessaging, "bridge_tg", message())
    assert fact.type == "jido.messaging.message.received"
    assert fact.data["bridge_id"] == "bridge_tg"
    assert fact.data["external_room_id"] == "chat_42"
    assert {:ok, stored} = TestMessaging.get_message(fact.data["message_id"])
    assert stored.external_id == "msg_100"
  end

  test "a duplicate normalized item does not write or observe again" do
    assert {:ok, [fact]} = InboundRouter.route_payload(TestMessaging, "bridge_tg", message())
    assert {:ok, []} = InboundRouter.route_payload(TestMessaging, "bridge_tg", message())
    assert {:ok, [_one]} = TestMessaging.list_messages(fact.data["room_id"])
  end

  test "raw event wrappers cannot enter the sink or become public facts" do
    assert {:error, %Jido.Chat.Errors.Contract{}} =
             InboundRouter.route_payload(TestMessaging, "bridge_tg", %{
               event_type: :reaction,
               payload: %{emoji: "🔥"},
               raw: %{private_token: "secret"}
             })

    assert TestMessaging.list_rooms() == {:ok, []}
  end

  test "webhook verification uses the captured credentials and settings" do
    {:ok, _} =
      TestMessaging.put_bridge_config(%{
        id: "config_aware",
        adapter_module: ConfigAwareAdapter,
        secret_refs: %{token: :bridge_secret},
        opts: %{parse_result: :noop}
      })

    assert {:ok, []} =
             InboundRouter.route_webhook(TestMessaging, "config_aware", %{"kind" => "noop"},
               headers: %{"authorization" => "bridge-secret"}
             )

    assert {:error, :invalid_signature} =
             InboundRouter.route_webhook(TestMessaging, "config_aware", %{"kind" => "noop"},
               headers: %{"authorization" => "wrong-secret"}
             )
  end

  test "acknowledgement-only input is an empty delivery" do
    assert {:ok, []} = InboundRouter.route_webhook(TestMessaging, "bridge_tg", %{"kind" => "noop"})
  end

  test "a normalized reaction is observed without message ingestion" do
    {:ok, _} = TestMessaging.subscribe_signals("jido.chat.reaction.added")
    payload = %{"kind" => "reaction", "room" => "chat_1", "id" => "msg_1", "emoji" => "👍"}
    assert {:ok, []} = InboundRouter.route_webhook(TestMessaging, "bridge_tg", payload)
    assert_receive {:signal, fact}
    assert fact.data["reaction"] == "👍"
    assert TestMessaging.list_rooms() == {:ok, []}
  end

  test "a verification failure prevents normalization and records" do
    {:ok, _} =
      TestMessaging.put_bridge_config(%{id: "reject", adapter_module: RouterAdapter, opts: %{reject_signature: true}})

    assert {:error, :invalid_signature} = InboundRouter.route_webhook(TestMessaging, "reject", message())
    assert TestMessaging.list_rooms() == {:ok, []}
  end

  test "an unknown bridge is rejected" do
    assert {:error, :bridge_not_found} = InboundRouter.route_webhook(TestMessaging, "missing", %{"kind" => "noop"})
  end

  test "a disabled bridge is rejected before normalization" do
    {:ok, _} = TestMessaging.put_bridge_config(%{id: "disabled", adapter_module: RouterAdapter, enabled: false})
    assert {:error, :bridge_disabled} = InboundRouter.route_payload(TestMessaging, "disabled", message())
    assert TestMessaging.list_rooms() == {:ok, []}
  end

  test "a private webhook response is separate from the empty public acceptance" do
    assert {:ok, %WebhookResponse{} = response, {:ok, []}} =
             InboundRouter.route_webhook_request(
               TestMessaging,
               "bridge_tg",
               %{headers: %{}, method: "POST", path: "/webhook", raw_body: ~s({"kind":"noop"})},
               %{"kind" => "noop"}
             )

    assert response.status == 200
    assert response.body == %{ok: true}
  end

  test "an unknown bridge gets a private 404 response" do
    assert {:ok, %WebhookResponse{} = response, {:error, :bridge_not_found}} =
             InboundRouter.route_webhook_request(
               TestMessaging,
               "missing",
               %{headers: %{}},
               %{"kind" => "noop"}
             )

    assert response.status == 404
    assert response.body == %{error: "ingress_rejected"}
  end

  test "a formatter failure gets a safe error response" do
    {:ok, _} =
      TestMessaging.put_bridge_config(%{
        id: "format_error",
        adapter_module: RouterAdapter,
        opts: %{force_format_error: true}
      })

    assert {:ok, %WebhookResponse{} = response, {:error, %Jido.Chat.Errors.Contract{}}} =
             InboundRouter.route_webhook_request(
               TestMessaging,
               "format_error",
               %{headers: %{}},
               %{"kind" => "structured_error", "private_token" => "secret"}
             )

    assert response.status == 400
    assert response.body == %{error: "ingress_rejected"}
    refute Jason.encode!(response.body) =~ "secret"
  end

  test "the ingress outcome wrapper and public raw routing aliases are absent" do
    refute Code.ensure_loaded?(Jido.Messaging.IngressOutcome)
    refute function_exported?(InboundRouter, :route_ingress, 6)
    refute function_exported?(TestMessaging, :route_webhook, 2)
    refute function_exported?(TestMessaging, :route_payload, 2)
  end
end
