defmodule Jido.Messaging.TypedRequestAdmissionTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Messaging.{AuthorizationScope, Runtime}
  alias Jido.Messaging.Signal.SendMessage

  @requests Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/catalog.json")
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("definitions")
            |> Enum.filter(&(&1["owner"] == "messaging" and &1["kind"] in ["command", "query"]))

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "admission", transport: transport)
    :ok = Runtime.register_binding(runtime, binding)

    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:test, binding.id, "provider-room", %{type: :group})

    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, _} =
      Instance.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})

    {:ok, grant} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope
      })

    {:ok,
     runtime: runtime,
     binding: binding,
     transport: transport,
     room: room,
     participant: participant,
     scope: scope,
     grant: grant,
     actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  defp fixtures do
    Enum.map(@requests, fn row -> Module.concat([row["module"]]).new!(row["fixture"]) end)
  end

  defp snapshot(context) do
    {_, state} = Runtime.get_persistence(context.runtime)
    Map.new(Map.from_struct(state), fn {key, table} -> {key, Enum.sort(:ets.tab2list(table))} end)
  end

  defp request(context) do
    SendMessage.new!(%{
      "request_id" => "logical-request",
      "bridge_id" => context.binding.id,
      "room_id" => context.room.id,
      "text" => "hello"
    })
  end

  defp assert_no_effects(context, before) do
    assert snapshot(context) == before
    assert MockTransport.calls(context.transport) == []
    assert :ets.tab2list(Runtime.request_table(context.runtime)) == []
  end

  test "all 36 public requests remain observations when published on the Bus", context do
    requests = fixtures()
    assert length(requests) == 36
    before = snapshot(context)
    {:ok, _} = Instance.subscribe_signals("jido.messaging.**")
    bus = Module.concat(Instance, SignalBus)

    assert {:ok, recorded} = Jido.Signal.Bus.publish(bus, requests)
    assert length(recorded) == 36

    for request <- requests do
      assert_receive {:signal, ^request}
    end

    assert_no_effects(context, before)
    refute_received {:signal, _}
  end

  test "all 36 public requests require a trusted actor before admission", context do
    before = snapshot(context)

    for request <- fixtures() do
      assert {:ok, denied} = Instance.execute(request, [])
      assert denied.type == "jido.messaging.operation.failed"
      assert denied.data["code"] == "authorization_denied"
      assert Jido.Signal.Context.get(denied, "causationid") == request.id
    end

    assert_no_effects(context, before)
  end

  test "every public request rejects an unknown schema before authority or effects", context do
    before = snapshot(context)

    for request <- fixtures() do
      assert {:error, _} = Instance.execute(%{request | dataschema: "urn:unknown:schema:1"}, context.actor)
    end

    assert_no_effects(context, before)
  end

  test "every public request rejects private data and changed context before effects", context do
    before = snapshot(context)

    for request <- fixtures() do
      assert {:error, _} = Instance.execute(%{request | data: Map.put(request.data, "private", self())}, context.actor)
      assert {:error, _} = Instance.execute(%{request | subject: "foreign-room"}, context.actor)
      assert {:error, _} = Instance.execute(%{request | id: String.duplicate("x", 129)}, context.actor)
    end

    assert_no_effects(context, before)
  end

  test "invalid public entry forms have no effects", context do
    before = snapshot(context)

    for value <- [nil, %{}, Jido.Signal.to_map(request(context))] do
      assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_request}} = Instance.execute(value, context.actor)
    end

    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_request}} = Instance.execute(request(context), %{})

    for scope <- [nil, %{}, :invalid] do
      assert {:ok, denied} =
               Instance.execute(request(context), Keyword.put(context.actor, :authorization_scope, scope))

      assert denied.data["code"] == "authorization_denied"
    end

    assert_no_effects(context, before)
  end

  test "a corrected authorization store can admit a request that had no prior effects", context do
    {_, state} = Runtime.get_persistence(context.runtime)
    :ets.insert(state.principal_grants, {"invalid-row", self()})
    before = snapshot(context)
    command = request(context)

    assert {:ok, failed} = Instance.execute(command, context.actor)
    assert failed.data["code"] == "authorization_store_failed"
    assert_no_effects(context, before)

    :ets.delete(state.principal_grants, "invalid-row")
    assert {:ok, completed} = Instance.execute(command, context.actor)
    assert completed.type == "jido.messaging.operation.completed"
    assert {:ok, ^completed} = Instance.execute(command, context.actor)
    assert length(MockTransport.calls(context.transport)) == 1
  end

  test "a changed grant revision cannot reuse an admitted outcome", context do
    command = request(context)
    assert {:ok, completed} = Instance.execute(command, context.actor)

    assert {:ok, _} =
             Instance.revise_principal_grant(context.grant.id, context.grant.revision, %{constraints: %{max_results: 2}})

    assert {:error, %Jido.Chat.Errors.Contract{code: :request_conflict}} = Instance.execute(command, context.actor)
    assert completed.type == "jido.messaging.operation.completed"
    assert length(MockTransport.calls(context.transport)) == 1
  end

  test "a new Signal ID with the same logical request returns the first outcome", context do
    command = request(context)
    assert {:ok, completed} = Instance.execute(command, context.actor)
    second = request(context)
    refute command.id == second.id

    assert {:ok, ^completed} = Instance.execute(second, context.actor)
    assert Jido.Signal.Context.get(completed, "causationid") == command.id
    assert length(MockTransport.calls(context.transport)) == 1
  end
end
