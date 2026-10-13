defmodule Jido.Messaging.LocalPostResourceFailureTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.{AuthorizationScope, Persistence.ETS, Runtime}
  alias Jido.Messaging.Signal.PostMessage

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name != :save_message do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_message(state, message) do
      mode = Agent.get_and_update(__MODULE__.Control, fn data -> {data.mode, %{data | attempts: data.attempts + 1}} end)

      case mode do
        :pass ->
          write(state, message)

        {:before, failure} ->
          fail(failure)

        {:after, failure} ->
          result = write(state, message)
          assert_result(result)
          fail(failure)
      end
    end

    defp write(state, message) do
      result = ETS.save_message(state, message)
      Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1, saved: message})
      result
    end

    defp assert_result({:ok, _}), do: :ok
    defp fail(:error), do: {:error, :private_store_unavailable}
    defp fail(:raise), do: raise("private message store")
    defp fail(:throw), do: throw(:private_message_store)
    defp fail(:exit), do: exit(:private_message_store)
    defp fail(:invalid), do: :invalid
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{mode: :pass, attempts: 0, writes: 0, saved: nil} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "resource-failure", transport: transport)
    runtime = Instance.__jido_messaging__(:runtime)
    :ok = Runtime.register_binding(runtime, binding)
    {:ok, room} = Instance.create_room(%{id: "owned-room", type: :group})
    {:ok, foreign_room} = Instance.create_room(%{id: "foreign-room", type: :group})
    {:ok, participant} = Instance.create_participant(%{id: "owner", type: :human})

    {:ok, foreign} =
      Instance.save_message(%{
        id: "foreign-message",
        room_id: foreign_room.id,
        sender_id: participant.id,
        role: :user,
        content: [%{type: :text, text: "Complete foreign content"}],
        metadata: %{complete: "foreign"}
      })

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope,
        constraints: %{requires_membership: false}
      })

    {:ok, _} = Instance.subscribe_signals("jido.messaging.room.message_added")
    Agent.update(Store.Control, fn _ -> %{mode: :pass, attempts: 0, writes: 0, saved: nil} end)

    request =
      PostMessage.new!(%{
        "request_id" => "large-local-post",
        "room_id" => room.id,
        "sender_id" => participant.id,
        "text" => ""
      })

    {:ok, json} = Jido.Signal.Serialization.serialize(request)
    request = %{request | data: Map.put(request.data, "text", String.duplicate("x", 262_144 - byte_size(json)))}
    assert {:ok, ^request} = Policy.validate(request)

    {:ok,
     runtime: runtime,
     transport: transport,
     room: room,
     foreign: foreign,
     request: request,
     actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  for phase <- [:before, :after], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{failure} #{phase} storage keeps confirmed state and cancels both prepared resources", context do
      Agent.update(Store.Control, &%{&1 | mode: {unquote(phase), unquote(failure)}})
      before = Jido.Signal.to_map(context.request)
      assert {:ok, failed} = Instance.execute(context.request, context.actor)
      assert failed.type == "jido.messaging.operation.failed"
      assert failed.data["code"] == "persistence_failed"
      assert Jido.Signal.Context.get(failed, "causationid") == context.request.id
      assert Jido.Signal.to_map(context.request) == before
      assert_prepared_cancelled(context)
      assert_state(context, unquote(phase) == :after)
      refute_receive {:signal, _}
      resources = resources(context)
      Agent.update(Store.Control, &%{&1 | mode: :pass})
      assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
      assert resources(context) == resources
      assert_state(context, unquote(phase) == :after)
      refute_receive {:signal, _}
    end
  end

  test "failed fact publication keeps one complete write and cancels prepared resources", context do
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Module.concat(Instance, SignalBus))
    {id, ^bus, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == bus end)
    :ok = Supervisor.terminate_child(supervisor, id)
    assert {:ok, failed} = Instance.execute(context.request, context.actor)
    assert failed.data["code"] == "observation_failed"
    assert_prepared_cancelled(context)
    assert_state(context, true)
    rows = resources(context)
    assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
    assert resources(context) == rows
    assert_state(context, true)
    refute_receive {:signal, _}
  end

  defp assert_prepared_cancelled(context) do
    rows = resources(context)
    assert length(rows) == 2
    states = Enum.map(rows, fn {{:resource, _}, _, kind, value, _, status} -> {kind, is_nil(value), status} end)
    assert states == [{"result", true, :cancelled}, {"result", true, :cancelled}]
  end

  defp resources(context) do
    owner = Runtime.resource_owner(context.runtime)
    owner.resources |> :ets.tab2list() |> Enum.filter(&match?({{:resource, _}, _, _, _, _, _}, &1)) |> Enum.sort()
  end

  defp assert_state(context, written) do
    control = Agent.get(Store.Control, & &1)
    assert control.attempts == 1
    assert control.writes == if(written, do: 1, else: 0)
    assert {:ok, messages} = Instance.list_messages(context.room.id)

    if written do
      assert messages == [control.saved]
      assert [%Jido.Chat.Content.Text{text: text}] = control.saved.content
      assert text == context.request.data["text"]
    else
      assert messages == []
    end

    assert {:ok, foreign} = Instance.get_message(context.foreign.id)
    assert foreign == context.foreign
    assert MockTransport.calls(context.transport) == []
    admissions = :ets.tab2list(Runtime.request_table(context.runtime)) |> Enum.filter(&(tuple_size(&1) == 4))
    assert length(admissions) == 1
    assert Instance.count_agents() == 0
  end
end
