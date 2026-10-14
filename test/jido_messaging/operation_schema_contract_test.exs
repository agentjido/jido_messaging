defmodule Jido.Messaging.OperationSchemaContractTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Operations.Definitions
  alias Jido.Messaging.Signal.{OperationCompleted, OperationFailed}

  # Captured from the compiled C1 contracts before C2. Do not regenerate these
  # fixtures for a refactor. A contract change requires a separate API decision.
  @signal_contracts __DIR__
                    |> Path.join("../fixtures/signal_contracts_v1.json")
                    |> File.read!()
                    |> Jason.decode!()
  @operation_contracts __DIR__
                       |> Path.join("../fixtures/operation_contracts_v1.json")
                       |> File.read!()
                       |> Jason.decode!()

  for contract <- @signal_contracts["signals"] do
    @contract contract
    test "public Signal contract: #{contract["type"]}" do
      module = Module.concat([@contract["module"]])
      assert module.type() == @contract["type"]
      assert module.dataschema() == @contract["dataschema"]
      assert Atom.to_string(module.__signal_kind__()) == @contract["kind"]

      assert Enum.map(module.__info__(:functions), fn {name, arity} -> "#{name}/#{arity}" end) ==
               @signal_contracts["exports"]

      hash =
        module.schema()
        |> Zoi.to_json_schema()
        |> canonical()
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert hash == @contract["schema_sha256"]
    end
  end

  for payload <- @operation_contracts["completed_samples"] do
    @payload payload
    test "baseline completed payload: #{payload["operation"]}" do
      assert {:ok, @payload} == OperationCompleted.validate_data(@payload)
      assert {:error, _} = OperationCompleted.validate_data(Map.put(@payload, "unexpected", true))
      assert {:error, _} = OperationCompleted.validate_data(Map.delete(@payload, "request_id"))
      assert {:error, _} = OperationCompleted.validate_data(Map.put(@payload, "request_id", ""))
      assert {:error, _} = OperationCompleted.validate_data(Map.delete(@payload, "result"))
    end
  end

  test "operation metadata retains every request, provider, and required action" do
    contracts = @operation_contracts["requests"]
    assert Enum.sort(Map.keys(Definitions.all())) == Enum.sort(Enum.map(contracts, & &1["type"]))

    for contract <- contracts do
      metadata = Definitions.lookup(contract["type"])
      assert inspect(metadata.definition) == contract["request"]
      assert metadata.operation == contract["operation"]
      assert Atom.to_string(metadata.action) == contract["action"]
      assert module_name(metadata.provider) == contract["provider"]
      assert Definitions.provider_definition(metadata.operation) == metadata.provider
    end

    for definition <- Jido.Messaging.signal_definitions(), definition.__signal_kind__() not in [:command, :query] do
      assert Definitions.lookup(definition.type()) == nil
    end

    assert Definitions.lookup("unknown") == nil
    assert Definitions.provider_definition("provider.unknown") == nil
    assert Definitions.route_operation() == "route_outbound"
    assert Definitions.lookup(Jido.Messaging.Signal.SendMessage.type()).operation == "provider.send_message"
  end

  test "result builders retain the compiled public schemas" do
    refinement = {Jido.Chat.Signal.Policy, :validate_json, []}
    assert Zoi.refine(Definitions.completed_schema(), refinement) == OperationCompleted.schema()
    assert Zoi.refine(Definitions.failed_schema(), refinement) == OperationFailed.schema()
  end

  test "tool projection metadata retains all existing action shapes" do
    assert Definitions.tool_shapes() == %{
             fetch_message: :message,
             fetch_channel_messages: :message_page,
             fetch_thread: :thread,
             fetch_thread_messages: :message_page,
             list_threads: :thread_page,
             lookup_participant: :user,
             lookup_user: :user,
             fetch_channel_metadata: :conversation,
             post_message: :message,
             post_channel_message: :message,
             send_direct_message: :message,
             start_typing: :acknowledgement,
             edit_message: :message,
             delete_message: :acknowledgement,
             add_reaction: :acknowledgement,
             remove_reaction: :acknowledgement
           }
  end

  test "message status values remain different for tools and provider or runtime results" do
    for operation <- ["provider.send_message", "post_message"] do
      assert_valid(operation, %{"id" => "message", "room_id" => "room", "status" => "sending"})
    end

    assert_invalid("tool.post_message", %{"id" => "message", "room_id" => "room", "status" => "sending"})
    assert_valid("tool.post_message", %{"id" => "message", "room_id" => "room", "status" => "pending"})
  end

  test "resource kinds keep the runtime post-message restriction" do
    for kind <- ["file", "media", "stream", "card", "modal", "result"] do
      result = resource(kind)
      assert_valid("provider.send_message", result)
      assert_valid("tool.post_message", result)

      if kind == "result", do: assert_valid("post_message", result), else: assert_invalid("post_message", result)
    end

    assert_invalid("create_room", resource("result"))
    assert_invalid("mark_read", resource("result"))
    assert_invalid("provider.send_message", put_in(resource("result"), ["resource_ref", "scope"], "room"))
    assert_invalid("provider.send_message", put_in(resource("result"), ["resource_ref", "id"], ""))
    assert_invalid("provider.send_message", put_in(resource("result"), ["resource_ref", "kind"], "unknown"))
  end

  test "nested messages reject extra keys and invalid fields but retain nullable references" do
    message = %{"id" => "message", "room_id" => "room", "thread_id" => nil, "reply_to_id" => nil}
    assert_valid("provider.send_message", message)
    assert_invalid("provider.send_message", Map.put(message, "unexpected", true))
    assert_invalid("provider.send_message", Map.put(message, "id", ""))
    assert_invalid("provider.send_message", Map.put(message, "text", nil))
    assert_invalid("provider.send_message", Map.put(message, "thread_id", ""))
    assert_invalid("provider.send_message", Map.put(message, "sender", %{"id" => ""}))
    assert_invalid("provider.send_message", Map.put(message, "sender", %{"id" => "sender", "extra" => true}))
    assert_invalid("provider.send_message", Map.put(message, "media", [%{"kind" => "image"}]))
  end

  test "pages require a nullable cursor and validate nested items" do
    page = %{"messages" => [], "complete" => true, "next_cursor" => nil}
    assert_valid("provider.fetch_messages", page)
    assert_invalid("provider.fetch_messages", Map.delete(page, "next_cursor"))
    assert_invalid("provider.fetch_messages", Map.put(page, "next_cursor", ""))
    assert_invalid("provider.fetch_messages", Map.put(page, "complete", nil))
    assert_invalid("provider.fetch_messages", Map.put(page, "messages", [%{"id" => "message"}]))
  end

  test "failure codes and optional route results remain limited to their operation groups" do
    provider = %{
      "operation" => "provider.send_message",
      "request_id" => "request",
      "code" => "provider_failure",
      "retryable" => true
    }

    tool = %{provider | "operation" => "tool.post_message", "code" => "provider_error"}
    route = %{provider | "operation" => "route_outbound"}
    summary = %{"attempted" => 0, "delivery_mode" => "best_effort", "delivered" => [], "failed" => []}

    assert {:ok, ^provider} = OperationFailed.validate_data(provider)
    assert {:ok, ^tool} = OperationFailed.validate_data(tool)
    assert {:ok, _} = OperationFailed.validate_data(Map.put(route, "result", summary))
    assert {:ok, _} = OperationFailed.validate_data(Map.put(route, "result", resource("result")))
    assert {:error, _} = OperationFailed.validate_data(%{provider | "code" => "provider_error"})
    assert {:error, _} = OperationFailed.validate_data(%{tool | "code" => "provider_failure"})
    assert {:error, _} = OperationFailed.validate_data(Map.put(provider, "result", summary))
    assert {:error, _} = OperationFailed.validate_data(Map.put(provider, "bridge_id", "bridge"))
    assert {:error, _} = OperationFailed.validate_data(Map.put(route, "result", %{summary | "attempted" => -1}))
  end

  defp canonical(value) when is_map(value) do
    {:object, value |> Enum.map(fn {key, child} -> {to_string(key), canonical(child)} end) |> Enum.sort()}
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
  defp module_name(nil), do: nil
  defp module_name(module), do: inspect(module)

  defp resource(kind),
    do: %{"resource_ref" => %{"id" => "resource", "binding_id" => "binding", "scope" => "call", "kind" => kind}}

  defp payload(operation, result) do
    fields = %{"operation" => operation, "request_id" => "request", "result" => result}
    if String.starts_with?(operation, ["provider.", "tool."]), do: Map.put(fields, "bridge_id", "bridge"), else: fields
  end

  defp assert_valid(operation, result) do
    data = payload(operation, result)
    assert {:ok, ^data} = OperationCompleted.validate_data(data)
  end

  defp assert_invalid(operation, result) do
    assert {:error, _} = OperationCompleted.validate_data(payload(operation, result))
  end
end
