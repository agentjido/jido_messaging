defmodule Jido.Messaging.ExecutionCanonicalScopeTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Messaging.{AuthorizationAction, AuthorizationScope, Persistence.ETS, Runtime}
  alias Jido.Messaging.Signal.{AddRoomReaction, EditMessage, SendMessage, SetPresence}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name not in [:get_message, :get_thread] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def get_message(state, id), do: read(:message, fn -> ETS.get_message(state, id) end)
    def get_thread(state, id), do: read(:thread, fn -> ETS.get_thread(state, id) end)

    defp read(operation, fun) do
      case Agent.get(__MODULE__.Control, &Map.get(&1, operation, :pass)) do
        :pass -> fun.()
        :error -> {:error, :scope_read_unavailable}
        :raise -> raise "private canonical scope"
        :throw -> throw(:private_canonical_scope)
        :exit -> exit(:private_canonical_scope)
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{id: Store.Control, start: {Agent, :start_link, [fn -> %{} end, [name: Store.Control]]}})
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "scope-binding", transport: transport)
    runtime = Instance.__jido_messaging__(:runtime)
    :ok = Runtime.register_binding(runtime, binding)
    {:ok, room} = Instance.get_or_create_room_by_external_binding(:test, binding.id, "provider-room", %{type: :group})
    {:ok, foreign_room} = Instance.create_room(%{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, message} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: [Jido.Chat.Content.Text.new("complete")],
        external_id: "provider-message"
      })

    {:ok, foreign_message} =
      Instance.save_message(%{
        room_id: foreign_room.id,
        sender_id: participant.id,
        role: :user,
        content: [Jido.Chat.Content.Text.new("foreign")],
        external_id: "provider-message"
      })

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: AuthorizationAction.all(),
        scope: scope,
        constraints: %{requires_membership: false}
      })

    {:ok,
     runtime: runtime,
     transport: transport,
     binding: binding,
     room: room,
     foreign_room: foreign_room,
     participant: participant,
     message: message,
     foreign_message: foreign_message,
     scope: scope}
  end

  test "a message scope accepts its canonical or provider ID and caches exactly one callback", context do
    scope =
      AuthorizationScope.new(%{
        kind: :message,
        room_id: context.room.id,
        message_id: context.message.id,
        bridge_id: context.binding.id
      })

    for {id, message_id} <- [{"canonical", context.message.id}, {"provider", context.message.external_id}] do
      parent = edit(context, id, message_id)
      before = Jido.Signal.to_map(parent)
      assert {:ok, result} = Instance.execute(parent, actor(context, scope))
      assert result.type == "jido.messaging.operation.completed"
      assert {:ok, ^result} = Instance.execute(parent, actor(context, scope))
      assert Jido.Signal.to_map(parent) == before
      assert Jido.Signal.Context.get(result, "causationid") == parent.id
    end

    assert length(MockTransport.calls(context.transport)) == 2
    assert_records(context)
  end

  test "foreign or missing canonical message scope has no provider or admission", context do
    for message <- [context.foreign_message.id, "missing"] do
      scope =
        AuthorizationScope.new(%{
          kind: :message,
          room_id: context.room.id,
          message_id: message,
          bridge_id: context.binding.id
        })

      assert {:ok, failed} =
               Instance.execute(edit(context, message, context.message.external_id), actor(context, scope))

      assert failed.data["code"] == "authorization_denied"
      assert_empty_effects(context)
    end
  end

  for operation <- [:message, :thread], failure <- [:error, :raise, :throw, :exit] do
    test "#{operation} #{failure} canonical read has no provider or admission", context do
      Agent.update(Store.Control, &Map.put(&1, unquote(operation), unquote(failure)))

      request =
        if unquote(operation) == :message do
          AddRoomReaction.new!(%{
            "request_id" => "read-failure",
            "room_id" => context.room.id,
            "message_id" => context.message.id,
            "participant_id" => context.participant.id,
            "reaction" => "👍"
          })
        else
          SendMessage.new!(%{
            "request_id" => "read-failure",
            "room_id" => context.room.id,
            "bridge_id" => context.binding.id,
            "thread_id" => "thread",
            "text" => "complete"
          })
        end

      assert {:ok, result} = Instance.execute(request, actor(context, context.scope))
      assert result.data["code"] == "authorization_store_failed"
      assert_empty_effects(context)
    end
  end

  test "missing or foreign local message cannot accept a runtime reaction", context do
    for message_id <- ["missing", context.foreign_message.id] do
      parent =
        AddRoomReaction.new!(%{
          "request_id" => message_id,
          "room_id" => context.room.id,
          "message_id" => message_id,
          "participant_id" => context.participant.id,
          "reaction" => "👍"
        })

      assert {:ok, result} = Instance.execute(parent, actor(context, context.scope))
      assert result.data["code"] == "authorization_denied"
      assert_empty_effects(context)
    end
  end

  test "local participant claims cannot replace the trusted principal", context do
    request =
      SetPresence.new!(%{
        "request_id" => "foreign-participant",
        "room_id" => context.room.id,
        "participant_id" => "foreign",
        "presence" => "away"
      })

    assert {:ok, result} = Instance.execute(request, actor(context, context.scope))
    assert result.data["code"] == "authorization_denied"
    assert {:ok, ^result} = Instance.execute(request, actor(context, context.scope))
    assert MockTransport.calls(context.transport) == []
    assert_records(context)
  end

  defp edit(context, id, message),
    do:
      EditMessage.new!(%{
        "request_id" => id,
        "room_id" => context.room.id,
        "bridge_id" => context.binding.id,
        "message_id" => message,
        "text" => "complete update"
      })

  defp actor(context, scope), do: [principal_id: context.participant.id, authorization_scope: scope]

  defp assert_empty_effects(context) do
    assert MockTransport.calls(context.transport) == []
    assert Jido.Messaging.TestHelpers.runtime_entry_count(context.runtime) == 0
    assert_records(context)
  end

  defp assert_records(context) do
    {_store, state} = Runtime.get_persistence(context.runtime)
    assert {:ok, message} = ETS.get_message(state, context.message.id)
    assert message == context.message
    assert {:ok, foreign} = ETS.get_message(state, context.foreign_message.id)
    assert foreign == context.foreign_message
    assert Instance.count_agents() == 0
    assert :ets.info(state.memberships, :size) == 0
  end
end
