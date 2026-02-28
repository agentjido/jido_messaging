defmodule Jido.Messaging.WebhookPlugTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Jido.Chat.{EventEnvelope, Incoming, WebhookRequest}
  alias Jido.Messaging.WebhookPlug

  defmodule ReadBodyErrorAdapter do
    def read_req_body(_payload), do: {:error, :timeout}
    def read_req_body(_payload, _opts), do: {:error, :timeout}

    defdelegate send_resp(payload, status, headers, body), to: Plug.Adapters.Test.Conn
    defdelegate send_file(payload, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
    defdelegate send_chunked(payload, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate chunk(payload, body), to: Plug.Adapters.Test.Conn
    defdelegate inform(payload, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(payload, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(payload), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(payload), to: Plug.Adapters.Test.Conn
    defdelegate get_sock_data(payload), to: Plug.Adapters.Test.Conn
    defdelegate get_ssl_data(payload), to: Plug.Adapters.Test.Conn
  end

  defmodule PlugAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(%{"kind" => "message"} = payload) do
      {:ok,
       Incoming.new(%{
         external_room_id: payload["room"] || "room",
         external_user_id: payload["user"] || "user",
         external_message_id: payload["id"] || "msg",
         text: payload["text"] || "hello",
         raw: payload
       })}
    end

    def transform_incoming(_payload), do: {:error, :unsupported_payload}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}

    @impl true
    def verify_webhook(%WebhookRequest{} = request, opts) do
      expected = Keyword.get(opts, :secret, "secret")
      actual = request.headers["x-test-secret"]
      if actual == expected, do: :ok, else: {:error, :invalid_signature}
    end

    @impl true
    def parse_event(%WebhookRequest{payload: %{"kind" => "noop"}}, _opts), do: {:ok, :noop}

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
           metadata: %{source: :webhook}
         })}
      end
    end
  end

  defmodule PlugMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(PlugMessaging)

    {:ok, _bridge} =
      PlugMessaging.put_bridge_config(%{
        id: "bridge_tg",
        adapter_module: PlugAdapter,
        enabled: true
      })

    :ok
  end

  test "routes valid webhook request and returns typed accepted response" do
    body = Jason.encode!(%{"kind" => "noop"})

    conn =
      conn(:post, "/webhooks/bridge_tg", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-test-secret", "abc")
      |> WebhookPlug.call(
        WebhookPlug.init(
          instance_module: PlugMessaging,
          bridge_id: "bridge_tg",
          route_opts: [secret: "abc"]
        )
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ok" => true}
  end

  test "rejects invalid webhook signature" do
    body = Jason.encode!(%{"kind" => "noop"})

    conn =
      conn(:post, "/webhooks/bridge_tg", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-test-secret", "bad")
      |> WebhookPlug.call(
        WebhookPlug.init(
          instance_module: PlugMessaging,
          bridge_id: "bridge_tg",
          route_opts: [secret: "abc"]
        )
      )

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_signature"
  end

  test "returns 400 for invalid JSON request bodies" do
    conn =
      conn(:post, "/webhooks/bridge_tg", "{invalid")
      |> put_req_header("content-type", "application/json")
      |> WebhookPlug.call(
        WebhookPlug.init(
          instance_module: PlugMessaging,
          bridge_id: "bridge_tg"
        )
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_json"
  end

  test "supports bridge_id resolver callback" do
    body = Jason.encode!(%{"kind" => "noop"})

    resolver = fn conn ->
      conn.request_path
      |> String.split("/", trim: true)
      |> List.last()
    end

    conn =
      conn(:post, "/webhooks/bridge_tg", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-test-secret", "abc")
      |> WebhookPlug.call(
        WebhookPlug.init(
          instance_module: PlugMessaging,
          bridge_id_resolver: resolver,
          route_opts: [secret: "abc"]
        )
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ok" => true}
  end

  test "returns controlled response when reading request body fails" do
    conn =
      conn(:post, "/webhooks/bridge_tg", ~s({"kind":"noop"}))
      |> put_req_header("content-type", "application/json")
      |> then(fn conn ->
        {_module, payload} = conn.adapter
        %{conn | adapter: {ReadBodyErrorAdapter, payload}}
      end)
      |> WebhookPlug.call(
        WebhookPlug.init(
          instance_module: PlugMessaging,
          bridge_id: "bridge_tg"
        )
      )

    assert conn.status == 408
    assert Jason.decode!(conn.resp_body)["error"] == "request_body_read_failed"
  end
end
