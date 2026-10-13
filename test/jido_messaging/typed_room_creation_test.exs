defmodule Jido.Messaging.TypedRoomCreationTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{AuthorizationScope, Runtime}
  alias Jido.Messaging.Signal.{CreateRoom, Identity}

  defmodule ControlledPersistence do
    @behaviour Jido.Messaging.Persistence

    for {name, arity} <- Jido.Messaging.Persistence.ETS.__info__(:functions), name != :save_room do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: Jido.Messaging.Persistence.ETS
    end

    def save_room(state, room) do
      Process.put({__MODULE__, :writes}, Process.get({__MODULE__, :writes}, 0) + 1)

      if Process.get({__MODULE__, :fail}),
        do: {:error, :store_unavailable},
        else: Jido.Messaging.Persistence.ETS.save_room(state, room)
    end
  end

  defmodule Instance do
    use Jido.Messaging,
      persistence: Jido.Messaging.TypedRoomCreationTest.ControlledPersistence,
      runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, participant} = Instance.create_participant(%{type: :human})
    scope = AuthorizationScope.new(%{kind: :bridge, bridge_id: "host-bridge"})

    {:ok, grant} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope,
        constraints: %{"requires_membership" => false}
      })

    {:ok, _} = Instance.subscribe_signals("jido.messaging.room.created")
    %{grant: grant, scope: scope, actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  defp request(extra \\ %{}) do
    CreateRoom.new!(Map.merge(%{"request_id" => "create-one", "name" => "New room", "kind" => "group"}, extra))
  end

  test "room creation uses the trusted bridge grant and returns the new canonical record", context do
    command = request()
    assert {:ok, result} = Instance.execute(command, context.actor)
    room_id = result.data["result"]["id"]
    assert is_binary(room_id)
    assert result.subject == Identity.room_subject(room_id)
    assert {:ok, room} = Instance.get_room(room_id)
    assert room.name == "New room"
    assert room.type == :group
    assert_receive {:signal, fact}
    assert fact.data["room_id"] == room_id
    assert fact.subject == result.subject

    for signal <- [fact, result] do
      assert Jido.Signal.Context.get(signal, "causationid") == command.id
      assert Jido.Signal.Trace.get(signal).trace_id == Jido.Signal.Trace.get(command).trace_id
      assert {:ok, json} = Jido.Signal.Serialization.serialize(signal)
      {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
      assert {:ok, ^signal} = Jido.Signal.Catalog.decode(catalog, json)
    end

    assert {:ok, ^result} = Instance.execute(command, context.actor)
    assert Process.get({ControlledPersistence, :writes}) == 1
    refute_receive {:signal, _}
  end

  test "a creation command cannot overwrite an existing room", context do
    {:ok, original} = Instance.create_room(%{id: "owned-room", type: :direct, name: "Existing"})
    scope = AuthorizationScope.new(%{kind: :room, room_id: original.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: context.actor[:principal_id],
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope,
        constraints: %{"requires_membership" => false}
      })

    actor = Keyword.put(context.actor, :authorization_scope, scope)

    assert {:error, %Jido.Chat.Errors.Contract{code: :request_conflict}} =
             Instance.execute(request(%{"room_id" => original.id}), actor)

    assert {:ok, ^original} = Instance.get_room(original.id)
    assert Process.get({ControlledPersistence, :writes}) == 1
    refute_receive {:signal, _}
  end

  test "a body target outside trusted scope cannot write", context do
    assert {:ok, denied} = Instance.execute(request(%{"room_id" => "outside"}), context.actor)
    assert denied.data["code"] == "authorization_denied"
    assert {:ok, []} = Instance.list_rooms()
    assert Process.get({ControlledPersistence, :writes}, 0) == 0
    refute_receive {:signal, _}
  end

  test "revoked authority cannot create a room", context do
    {:ok, _} = Instance.revoke_principal_grant(context.grant.id, context.grant.revision)
    assert {:ok, denied} = Instance.execute(request(), context.actor)
    assert denied.data["code"] == "authorization_denied"
    assert {:ok, []} = Instance.list_rooms()
    assert Process.get({ControlledPersistence, :writes}, 0) == 0
    refute_receive {:signal, _}
  end

  test "a terminal store failure is retained without another write", context do
    Process.put({ControlledPersistence, :fail}, true)
    command = request()
    assert {:ok, failed} = Instance.execute(command, context.actor)
    assert failed.data["code"] == "persistence_failed"
    assert {:ok, []} = Instance.list_rooms()
    Process.delete({ControlledPersistence, :fail})
    assert {:ok, ^failed} = Instance.execute(command, context.actor)
    assert Process.get({ControlledPersistence, :writes}) == 1
    refute_receive {:signal, _}

    assert {:ok, completed} = Instance.execute(request(%{"request_id" => "create-two"}), context.actor)
    assert {:ok, _} = Instance.get_room(completed.data["result"]["id"])
    assert Process.get({ControlledPersistence, :writes}) == 2
    assert_receive {:signal, %{type: "jido.messaging.room.created"}}
  end

  test "a room posting grant cannot allocate a room outside its scope", context do
    {:ok, original} = Instance.create_room(%{id: "owned-room", type: :group, name: "Owned"})
    scope = AuthorizationScope.new(%{kind: :room, room_id: original.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: context.actor[:principal_id],
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope,
        constraints: %{"requires_membership" => false}
      })

    actor = Keyword.put(context.actor, :authorization_scope, scope)
    assert {:ok, denied} = Instance.execute(request(), actor)
    assert denied.data["code"] == "authorization_denied"
    assert {:ok, [^original]} = Instance.list_rooms()
    assert Process.get({ControlledPersistence, :writes}) == 1
    refute_receive {:signal, _}
  end

  test "the low-level room record helper does not emit a communication fact" do
    assert {:ok, room} = Instance.create_room(%{id: "bootstrap-room", type: :group, name: "Bootstrap"})
    assert {:ok, ^room} = Instance.get_room(room.id)
    refute_receive {:signal, _}
  end

  test "creation supports each stored room kind and rejects unknown kind", context do
    for kind <- ~w(direct group channel thread) do
      command = request(%{"request_id" => "kind-#{kind}", "kind" => kind})
      assert {:ok, result} = Instance.execute(command, context.actor)
      assert result.data["result"]["kind"] == kind
      assert {:ok, room} = Instance.get_room(result.data["result"]["id"])
      assert Atom.to_string(room.type) == kind
    end

    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_request}} =
             CreateRoom.new(%{"request_id" => "unknown", "name" => "Unknown", "kind" => "unknown"})

    assert {:ok, rooms} = Instance.list_rooms()
    assert length(rooms) == 4
    assert Process.get({ControlledPersistence, :writes}) == 4
  end
end
