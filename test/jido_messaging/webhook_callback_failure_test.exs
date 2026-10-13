defmodule Jido.Messaging.WebhookCallbackFailureTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Jido.Chat.{WebhookRequest, WebhookResponse}
  alias Jido.Messaging.WebhookPlug

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :webhook_failure_fixture
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, %WebhookRequest{payload: payload}) do
      send(Process.whereis(__MODULE__.Probe), {:webhook_callback, :normalize})

      signals =
        if payload["kind"] == "message",
          do: [
            Jido.Chat.AdapterTestKit.Factories.message_received(
              binding,
              %{
                "delivery_id" => "owned",
                "item_id" => "owned",
                "room_id" => "owned-room",
                "message_id" => "owned-message",
                "sender" => %{"id" => "owned-user"},
                "text" => "complete text"
              }
            )
          ],
          else: []

      Jido.Chat.Delivery.new(binding, "owned", signals)
    end

    @impl true
    def verify_webhook(_request, opts), do: reply(Keyword.fetch!(opts, :settings)[:verify], :verify)
    @impl true
    def format_webhook_response(result, opts) do
      case reply(Keyword.fetch!(opts, :settings)[:format], :format) do
        %WebhookResponse{} when elem(result, 0) == :error -> WebhookResponse.error(400, %{error: "ingress_rejected"})
        response -> response
      end
    end

    defp reply(value, stage) do
      send(Process.whereis(__MODULE__.Probe), {:webhook_callback, stage})

      case value do
        :raise -> raise "private callback failure"
        :throw -> throw(:private_callback_failure)
        :exit -> exit(:private_callback_failure)
        :invalid -> :invalid
        nil when stage == :verify -> :ok
        nil -> WebhookResponse.accepted()
        value -> value
      end
    end
  end

  setup do
    Process.register(self(), Adapter.Probe)
    start_supervised!(Instance)
    :ok
  end

  for failure <- [:raise, :throw, :exit, :invalid] do
    test "#{failure} verifier failure rejects before normalization" do
      configure(%{verify: unquote(failure)})
      response = call_plug()
      assert response.status == 400
      assert Jason.decode!(response.resp_body) == %{"error" => "ingress_rejected"}
      assert_receive {:webhook_callback, :verify}
      assert_receive {:webhook_callback, :format}
      refute_receive {:webhook_callback, :normalize}, 0
      assert {:ok, []} = Instance.list_rooms()
    end
  end

  for failure <- [:raise, :throw, :exit] do
    test "#{failure} response formatter failure does not repeat acceptance" do
      configure(%{format: unquote(failure)})
      response = call_plug()
      assert response.status == 200
      assert_receive {:webhook_callback, :verify}
      assert_receive {:webhook_callback, :normalize}
      assert_receive {:webhook_callback, :format}
      refute_receive {:webhook_callback, _}, 0
      assert {:ok, []} = Instance.list_rooms()
    end
  end

  test "formatter exception after a message write cannot repeat that write" do
    configure(%{format: :raise})
    assert call_plug(~s({"kind":"message"})).status == 200

    assert {:ok, message} =
             Instance.get_message_by_external_id(:webhook_failure_fixture, "owned-bridge", "owned-message")

    assert call_plug(~s({"kind":"message"})).status == 200
    assert {:ok, [^message]} = Instance.list_messages(message.room_id)
    assert message.content |> hd() |> Map.fetch!(:text) == "complete text"
  end

  defp configure(settings) do
    assert {:ok, _} = Instance.put_bridge_config(%{id: "owned-bridge", adapter_module: Adapter, opts: settings})
  end

  defp call_plug(body \\ "{}") do
    conn(:post, "/owned", body)
    |> WebhookPlug.call(instance_module: Instance, bridge_id: "owned-bridge")
  end
end
