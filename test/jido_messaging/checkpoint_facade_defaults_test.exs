defmodule Jido.Messaging.CheckpointFacadeDefaultsTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.MockAdapter, Room}
  alias Jido.Messaging
  alias Jido.Messaging.{Runtime, Thread}

  defmodule Instance do
    use Messaging, persistence: Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(Instance)
    {:ok, runtime: Instance.__jido_messaging__(:runtime)}
  end

  test "direct canonical defaults preserve complete thread and message records", %{runtime: runtime} do
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, person} = Instance.create_participant(%{type: :human, identity: %{name: "Checkpoint"}})

    {:ok, message} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: person.id,
        role: :user,
        content: [%{type: :text, text: "complete content"}],
        external_id: "provider-message",
        metadata: %{channel: :test, bridge_id: "bridge"}
      })

    assert {:ok, ^message} = Messaging.get_message_by_external_id(runtime, :test, "bridge", "provider-message")
    assert {:ok, ^message} = Messaging.get_message_by_external_id(runtime, :test, "bridge", "provider-message", room.id)
    updated = %{message | metadata: Map.put(message.metadata, :complete, true)}
    assert {:ok, ^updated} = Messaging.save_message_struct(runtime, updated)
    thread = Thread.new(%{room_id: room.id, root_message_id: message.id, external_thread_id: "provider-thread"})
    assert {:ok, ^thread} = Messaging.save_thread_struct(runtime, thread)
    assert {:ok, ^thread} = Messaging.get_thread_by_external_id(runtime, room.id, "provider-thread")
    assert {:ok, ^thread} = Messaging.get_thread_by_root_message(runtime, room.id, message.id)
    assert {:ok, [^thread]} = Messaging.list_threads(runtime, room.id)
    assert {:ok, ^person} = Messaging.directory_lookup(runtime, :participant, %{id: person.id})
    assert {:ok, [^person]} = Messaging.directory_search(runtime, :participant, %{name: "check"})
    assert {:error, :not_found} = Messaging.directory_lookup(runtime, :participant, %{id: "foreign"})
    assert {:ok, []} = Messaging.list_threads(runtime, "foreign")
    assert {:error, :agent_directory_scope_required} = Messaging.directory_lookup(runtime, :agent, %{})
    assert {:error, :agent_directory_scope_required} = Messaging.directory_search(runtime, :agent, %{})
    assert :ets.info(Runtime.request_table(runtime), :size) == 0
  end

  test "stored configuration input keeps declared fields and rejects private credential storage" do
    at = ~U[2026-10-13 12:00:00Z]

    input = %{
      "id" => "bridge-record",
      "adapter_module" => MockAdapter,
      "credentials" => %{token: "fixture-private"},
      "secret_refs" => %{api: "opaque-ref"},
      "opts" => %{nested: ["complete"]},
      "enabled" => false,
      "capabilities" => %{send_message: :native},
      "delivery_policy" => :invalid,
      "revision" => 4,
      "inserted_at" => at,
      "updated_at" => at,
      "unknown" => "discard",
      12 => "discard"
    }

    config = Messaging.BridgeConfig.new(input)
    assert config.id == "bridge-record"
    assert config.credentials == %{}
    assert config.secret_refs == %{api: "opaque-ref"}
    assert config.opts == %{nested: ["complete"]}
    refute config.enabled
    assert config.inserted_at == at
    assert config.updated_at == at
    assert :ok = Messaging.BridgeConfig.validate_for_storage(config)

    assert {:error, {:bridge_credentials_migration_required, "bridge-record"}} =
             Messaging.BridgeConfig.validate_for_storage(%{config | credentials: %{token: "fixture-private"}})

    bumped = Messaging.BridgeConfig.bump_revision(config)
    assert bumped.revision == 5
    assert bumped.id == config.id
    assert bumped.secret_refs == config.secret_refs
    assert Messaging.BridgeConfig.adapter_opts(config)[:settings] == config.opts
    assert Messaging.BridgeConfig.adapter_opts(config, settings: %{override: true})[:settings] == %{override: true}

    policy =
      Messaging.RoutingPolicy.new(%{
        "id" => "policy",
        "room_id" => "room",
        "delivery_mode" => "broadcast",
        "failover_policy" => "none",
        "dedupe_scope" => "thread",
        "fallback_order" => ["bridge"],
        "metadata" => %{complete: true},
        "revision" => 2,
        "inserted_at" => at,
        "updated_at" => at,
        "unknown" => :discard,
        12 => :discard
      })

    assert policy.delivery_mode == :broadcast
    assert policy.failover_policy == :none
    assert policy.dedupe_scope == :thread
    assert policy.fallback_order == ["bridge"]
    assert policy.metadata == %{complete: true}
    assert policy.inserted_at == at
    assert policy.updated_at == at
    assert Messaging.RoutingPolicy.bump_revision(policy).revision == 3
    assert {:ok, ^policy} = Zoi.parse(Messaging.RoutingPolicy.schema(), policy)
  end

  test "onboarding facade defaults preserve terminal state and reject duplicate effects" do
    assert {:ok, flow} = Messaging.start_onboarding(Instance, %{onboarding_id: "cancel-default"})
    assert flow.status == :started
    assert is_pid(Messaging.whereis_onboarding_worker(Instance, flow.onboarding_id))
    assert {:ok, %{flow: cancelled}} = Messaging.cancel_onboarding(Instance, flow.onboarding_id)
    assert cancelled.status == :cancelled
    assert {:ok, persisted} = Messaging.get_onboarding(Instance, flow.onboarding_id)
    assert persisted == cancelled
    assert {:ok, _} = Messaging.start_onboarding(Instance, %{onboarding_id: "complete-default"})
    assert {:ok, _} = Messaging.advance_onboarding(Instance, "complete-default", :resolve_directory)
    assert {:ok, _} = Messaging.advance_onboarding(Instance, "complete-default", :pair_identity)
    assert {:ok, %{flow: completed}} = Messaging.complete_onboarding(Instance, "complete-default")
    assert completed.status == :completed
    assert {:ok, ^completed} = Messaging.get_onboarding(Instance, "complete-default")
    assert {:error, :not_found} = Messaging.resume_onboarding(Instance, "foreign")
  end

  test "invalid or unregistered resource owners cannot read or cancel another binding" do
    for ref <- [%{}, %{"binding_id" => "foreign"}, %{"binding_id" => 12}] do
      assert {:error, %{code: :invalid_resource}} = Instance.resolve_resource(ref)
      assert {:error, %{code: :invalid_resource}} = Instance.cancel_resource(ref)
    end
  end

  test "bridge room configuration retains string fields and exact provider identity" do
    config = %{
      "id" => "bridge",
      "adapter" => MockAdapter,
      "credentials" => %{},
      "opts" => %{},
      "capabilities" => %{},
      "delivery_policy" => %{},
      "revision" => 0
    }

    binding = %{
      "channel" => "discord",
      "bridge_id" => "bridge",
      "external_room_id" => 123,
      "direction" => "outbound",
      "enabled" => "1"
    }

    assert {:ok, %Room{id: "checkpoint-room"}} =
             Instance.create_bridge_room(%{room_id: "checkpoint-room", bridge_configs: [config], bindings: [binding]})

    assert {:ok, [saved]} = Instance.list_room_bindings("checkpoint-room")
    assert saved.channel == :discord
    assert saved.external_room_id == "123"
    assert saved.direction == :outbound
    assert saved.enabled
    assert {:ok, bridge} = Instance.get_bridge_config("bridge")
    assert bridge.adapter_module == MockAdapter
    assert bridge.revision == 1
    assert {:ok, _} = Instance.create_bridge_room(%{room_id: "checkpoint-room", bindings: [binding]})
    assert {:ok, [^saved]} = Instance.list_room_bindings("checkpoint-room")
    # The adapter declares :test. A :discord binding cannot become its route.
    assert {:ok, []} = Messaging.resolve_outbound_routes(Instance, "checkpoint-room")
  end

  test "agent registration requires an identity and normalizes default handles" do
    {:ok, room} = Instance.create_room(%{type: :group})
    assert_raise ArgumentError, "agent_spec requires :agent_id", fn -> Instance.register_agent(room.id, %{}) end

    assert {:ok, agent} =
             Instance.register_agent(room.id, %{id: "Casey", name: "CASEY", mention_handles: ["Casey", "CASEY", nil]})

    assert agent.agent_id == "Casey"
    assert agent.mention_handles == ["casey"]
    assert :ok = Instance.unregister_agent(room.id, "Casey")
    assert Instance.count_agents() == 0
  end
end
