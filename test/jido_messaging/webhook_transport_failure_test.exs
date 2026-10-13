defmodule Jido.Messaging.WebhookTransportFailureTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Jido.Messaging.WebhookPlug

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule BodyAdapter do
    def read_req_body(payload, _opts) do
      send(self(), :body_read)

      case Process.get(:body_steps) do
        [{:more, body} | rest] ->
          Process.put(:body_steps, rest)
          {:more, body, payload}

        [{:ok, body} | rest] ->
          Process.put(:body_steps, rest)
          {:ok, body, payload}

        [{:error, reason} | rest] ->
          Process.put(:body_steps, rest)
          {:error, reason}
      end
    end

    defdelegate send_resp(payload, status, headers, body), to: Plug.Adapters.Test.Conn
  end

  setup do
    start_supervised!(Instance)
    :ok
  end

  test "missing instance rejects before resolver and body read" do
    resolver = fn _ ->
      send(self(), :resolver_called)
      "owned"
    end

    response = conn(:post, "/owned", "{}") |> WebhookPlug.call(bridge_id_resolver: resolver)
    assert response.status == 500
    assert Jason.decode!(response.resp_body) == %{"error" => "missing_instance_module"}
    refute_receive :resolver_called, 0
  end

  test "missing bridge rejects before reading body" do
    response = body_conn([{:ok, "{}"}]) |> WebhookPlug.call(instance_module: Instance)
    assert response.status == 400
    assert Jason.decode!(response.resp_body) == %{"error" => "missing_bridge_id"}
    refute_receive :body_read, 0
  end

  for failure <- [:raise, :throw, :exit] do
    test "#{failure} bridge resolver returns safe failure before body read" do
      resolver = fn _ -> resolver_failure(unquote(failure)) end
      response = body_conn([{:ok, "{}"}]) |> WebhookPlug.call(instance_module: Instance, bridge_id_resolver: resolver)
      assert response.status == 400
      assert Jason.decode!(response.resp_body) == %{"error" => "missing_bridge_id"}
      refute_receive :body_read, 0
    end
  end

  for {reason, status} <- [{:timeout, 408}, {:too_large, 413}, {{:too_large, 20}, 413}, {:closed, 400}] do
    for prefix <- [[], [{:more, "{\"part\":"}]] do
      test "#{inspect(reason)} body failure after #{length(prefix)} chunk returns #{status}" do
        response =
          body_conn(unquote(Macro.escape(prefix)) ++ [{:error, unquote(Macro.escape(reason))}])
          |> WebhookPlug.call(instance_module: Instance, bridge_id: "owned")

        assert response.status == unquote(status)
        assert Jason.decode!(response.resp_body) == %{"error" => "request_body_read_failed"}
        assert {:ok, []} = Instance.list_rooms()
      end
    end
  end

  for body <- ["[]", "null", "1", "\"text\""] do
    test "non-object JSON #{body} fails before ingress" do
      response = conn(:post, "/owned", unquote(body)) |> WebhookPlug.call(instance_module: Instance, bridge_id: "owned")
      assert response.status == 400
      assert Jason.decode!(response.resp_body) == %{"error" => "invalid_json"}
      assert {:ok, []} = Instance.list_rooms()
    end
  end

  test "complete chunks are decoded once before unknown bridge response" do
    response =
      body_conn([{:more, "{"}, {:more, "\"kind\": "}, {:ok, "\"noop\"}"}])
      |> WebhookPlug.call(instance_module: Instance, bridge_id: "missing")

    assert response.status == 404
    assert Jason.decode!(response.resp_body) == %{"error" => "ingress_rejected"}
    assert_receive :body_read
    assert_receive :body_read
    assert_receive :body_read
    refute_receive :body_read, 0
  end

  test "fixed bridge does not invoke a failed resolver" do
    resolver = fn _ ->
      send(self(), :resolver_called)
      raise "must not run"
    end

    response =
      conn(:post, "/owned", "{}")
      |> WebhookPlug.call(instance_module: Instance, bridge_id: "missing", bridge_id_resolver: resolver)

    assert response.status == 404
    refute_receive :resolver_called, 0
  end

  test "blank body is an empty object before bridge resolution" do
    response = conn(:post, "/owned", " \n\t") |> WebhookPlug.call(instance_module: Instance, bridge_id: "missing")
    assert response.status == 404
    assert Jason.decode!(response.resp_body) == %{"error" => "ingress_rejected"}
  end

  defp body_conn(steps) do
    Process.put(:body_steps, steps)
    request = conn(:post, "/owned", "")
    {_adapter, payload} = request.adapter
    %{request | adapter: {BodyAdapter, payload}}
  end

  defp resolver_failure(:raise), do: raise("private resolver failure")
  defp resolver_failure(:throw), do: throw(:private_resolver_failure)
  defp resolver_failure(:exit), do: exit(:private_resolver_failure)
end
