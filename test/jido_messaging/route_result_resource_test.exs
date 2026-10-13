defmodule Jido.Messaging.RouteResultResourceTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{AuthorizationScope, Events, Runtime}
  alias Jido.Messaging.Signal.{Identity, SendMessage}

  defmodule Adapter do
    use Jido.Chat.Adapter
    def channel_type, do: :route_result
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])

    def send_message(room, text, opts) do
      Agent.update(__MODULE__.Control, &(&1 ++ [{room, text}]))

      if opts[:bridge_config] && opts[:bridge_config].opts[:fail],
        do: {:error, :send_failed},
        else: {:ok, %{"id" => room <> String.duplicate("x", 140_000), "room_id" => room}}
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(%{id: Adapter.Control, start: {Agent, :start_link, [fn -> [] end, [name: Adapter.Control]]}})
    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, foreign_room} = Instance.create_room(%{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    messages =
      for canonical_room <- [room, foreign_room] do
        {:ok, message} =
          Instance.save_message(%{
            room_id: canonical_room.id,
            sender_id: participant.id,
            role: :user,
            content: [Jido.Chat.Content.Text.new("Complete canonical content")]
          })

        message
      end

    bindings =
      for id <- ["first", "second"] do
        {:ok, _} = Instance.put_bridge_config(%{id: id, adapter_module: Adapter})
        {:ok, _} = Instance.create_room_binding(room.id, :route_result, id, "provider-" <> id)
        {:ok, binding} = Runtime.ensure_binding(runtime, Adapter, id, [])
        {:ok, ref} = Jido.Chat.put_resource(binding, "result", %{"complete" => id})
        {binding, ref, :ets.tab2list(binding.resources)}
      end

    {:ok, _} = Instance.put_routing_policy(room.id, %{delivery_mode: :broadcast, fallback_order: ["first", "second"]})
    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope,
        constraints: %{requires_membership: false}
      })

    request = SendMessage.new!(%{"request_id" => "one-broadcast", "room_id" => room.id, "text" => "hello"})

    expected = %{
      "attempted" => 2,
      "delivery_mode" => "broadcast",
      "delivered" =>
        for id <- ["first", "second"] do
          %{"bridge_id" => id, "message_id" => "provider-" <> id <> String.duplicate("x", 140_000), "attempts" => 1}
        end,
      "failed" => []
    }

    {:ok,
     runtime: runtime,
     room: room,
     messages: messages,
     bindings: bindings,
     request: request,
     expected: expected,
     actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  test "large broadcast result preserves all routes under the creator resource owner", context do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.operation.completed")
    before = Jido.Signal.to_map(context.request)
    assert {:ok, completed} = Instance.execute(context.request, context.actor)
    assert completed.type == "jido.messaging.operation.completed"
    assert completed.subject == Identity.room_subject(context.room.id)
    assert completed.source == Events.source(Instance)
    ref = completed.data["result"]["resource_ref"]
    assert is_map(ref)
    assert {:ok, result} = Instance.resolve_resource(ref)
    assert result == context.expected
    assert_receive {:signal, ^completed}
    assert Jido.Signal.Context.get(completed, "causationid") == context.request.id
    assert Jido.Signal.Trace.get(completed).trace_id == Jido.Signal.Trace.get(context.request).trace_id
    assert Jido.Signal.to_map(context.request) == before
    assert {:ok, ^completed} = Instance.execute(context.request, context.actor)
    assert Agent.get(Adapter.Control, & &1) == [{"provider-first", "hello"}, {"provider-second", "hello"}]
    task = Task.async(fn -> Instance.resolve_resource(ref) end)
    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_owner_mismatch}} = Task.await(task)
    assert {:ok, ^result} = Instance.resolve_resource(ref)
    assert_existing(context)
    refute_receive {:signal, _}
  end

  test "failed broadcast result publication clears only the unpublished resource and cannot resend", context do
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    {id, ^bus, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == bus end)
    :ok = Supervisor.terminate_child(supervisor, id)
    assert {:ok, failed} = Instance.execute(context.request, context.actor)
    assert failed.type == "jido.messaging.operation.failed"
    assert failed.data["code"] == "observation_failed"

    new_resources =
      for {binding, _, old_rows} <- context.bindings,
          row <- :ets.tab2list(binding.resources) -- old_rows,
          match?({{:resource, _}, _, _, _, _, _}, row),
          do: row

    assert [{{:resource, _}, _, "result", nil, _, :cancelled}] = new_resources
    snapshot = for {binding, _, _} <- context.bindings, do: :ets.tab2list(binding.resources) |> Enum.sort()
    assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
    assert snapshot == for({binding, _, _} <- context.bindings, do: :ets.tab2list(binding.resources) |> Enum.sort())
    assert Agent.get(Adapter.Control, & &1) == [{"provider-first", "hello"}, {"provider-second", "hello"}]
    assert_existing(context)
  end

  test "large all-failed result retains every route and failure detail without a repeat", context do
    {context, routes} = add_failed_routes(context)
    {:ok, _} = Instance.subscribe_signals("jido.messaging.operation.failed")
    before = Jido.Signal.to_map(context.request)
    assert {:ok, failed} = Instance.execute(context.request, context.actor)
    assert failed.type == "jido.messaging.operation.failed"
    assert failed.data["code"] == "provider_failure"
    assert failed.data["retryable"] == false

    assert byte_size(
             Jason.encode!(%{
               "attempted" => 1_400,
               "delivery_mode" => "broadcast",
               "delivered" => [],
               "failed" => routes
             })
           ) > 262_144

    assert failed.subject == Identity.room_subject(context.room.id)
    assert {:ok, result} = Instance.resolve_resource(failed.data["result"]["resource_ref"])
    assert result == %{"attempted" => 1_400, "delivery_mode" => "broadcast", "delivered" => [], "failed" => routes}
    assert_receive {:signal, ^failed}
    assert Jido.Signal.to_map(context.request) == before
    assert Jido.Signal.Context.get(failed, "causationid") == context.request.id
    assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
    assert Agent.get(Adapter.Control, & &1) == for(index <- 1..1_400, do: {"failed-#{index}", "hello"})
    assert_existing(context)
    refute_receive {:signal, _}
  end

  test "failed publication of a large failure result cancels its reference and preserves callbacks", context do
    {context, _routes} = add_failed_routes(context)
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    {id, ^bus, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == bus end)
    :ok = Supervisor.terminate_child(supervisor, id)
    assert {:ok, failed} = Instance.execute(context.request, context.actor)
    assert failed.data["code"] == "observation_failed"

    new_resources =
      for {binding, _, old_rows} <- context.bindings,
          row <- :ets.tab2list(binding.resources) -- old_rows,
          match?({{:resource, _}, _, _, _, _, _}, row),
          do: row

    assert [{{:resource, _}, _, "result", nil, _, :cancelled}] = new_resources
    snapshot = for {binding, _, _} <- context.bindings, do: :ets.tab2list(binding.resources) |> Enum.sort()
    assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
    assert snapshot == for({binding, _, _} <- context.bindings, do: :ets.tab2list(binding.resources) |> Enum.sort())
    assert Agent.get(Adapter.Control, & &1) == for(index <- 1..1_400, do: {"failed-#{index}", "hello"})
    assert_existing(context)
  end

  defp add_failed_routes(context) do
    {:ok, old_bindings} = Instance.list_room_bindings(context.room.id)
    for binding <- old_bindings, do: :ok = Instance.delete_room_binding(binding.id)

    routes =
      for index <- 1..1_400 do
        bridge = "failed-#{index}" <> String.duplicate("y", 110)
        {:ok, _} = Instance.put_bridge_config(%{id: bridge, adapter_module: Adapter, opts: %{fail: true}})
        {:ok, _} = Instance.create_room_binding(context.room.id, :route_result, bridge, "failed-#{index}")
        {:ok, binding} = Runtime.ensure_binding(context.runtime, Adapter, bridge, [])
        {:ok, ref} = Jido.Chat.put_resource(binding, "result", %{"complete" => bridge})
        {binding, ref, :ets.tab2list(binding.resources)}
      end

    ids = Enum.map(routes, fn {binding, _, _} -> binding.id end)
    {:ok, _} = Instance.put_routing_policy(context.room.id, %{delivery_mode: :broadcast, fallback_order: ids})
    failures = Enum.map(ids, &%{"bridge_id" => &1, "code" => "provider_failure", "retryable" => false, "attempts" => 1})
    {%{context | bindings: context.bindings ++ routes}, failures}
  end

  defp assert_existing(context) do
    for {binding, ref, old_rows} <- context.bindings do
      for row <- old_rows, do: assert(row in :ets.tab2list(binding.resources))
      assert {:ok, %{"complete" => id}} = Instance.resolve_resource(ref)
      assert id == binding.id
    end

    for message <- context.messages, do: assert({:ok, message} == Instance.get_message(message.id))
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 1
    assert Instance.count_agents() == 0
    assert {:ok, []} = Instance.list_memberships(context.room.id)
  end
end
