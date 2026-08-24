defmodule Jido.Messaging.AuthorizationTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Chat.{MessagingTarget, Participant, Room}

  alias Jido.Messaging.{
    AuthorizationDecision,
    AuthorizationScope,
    ChatActions,
    Grant,
    InvocationPolicy,
    Membership
  }

  alias Jido.Messaging.ChatActions.{Policy, Scope}
  alias Jido.Messaging.ChatActions.Messenger.PostMessage
  alias Jido.Messaging.ChatActions.Reader.FetchChannelMessages
  alias Jido.Messaging.Persistence.SQLite

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule ActionMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule ActionAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :authorization_test

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def capabilities, do: %{post_message: :native, fetch_channel_messages: :native}

    @impl true
    def post_message(room_id, payload, opts) do
      send(Application.fetch_env!(:jido_messaging, :authorization_test_pid), {
        :authorized_provider_call,
        room_id,
        payload,
        opts
      })

      {:ok, %{external_message_id: "authorized-1", external_room_id: room_id}}
    end

    @impl true
    def send_message(room_id, text, opts), do: post_message(room_id, %{text: text}, opts)

    @impl true
    def fetch_channel_messages(room_id, opts) do
      send(Application.fetch_env!(:jido_messaging, :authorization_test_pid), {
        :authorized_read_call,
        room_id,
        opts
      })

      {:ok, %{messages: []}}
    end
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido-messaging-authorization-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})
    start_supervised!(ActionMessaging)
    Application.put_env(:jido_messaging, :authorization_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:jido_messaging, :authorization_test_pid)
      File.rm(path)
    end)

    :ok
  end

  test "grants exact agent messaging scope and separates invocation policy" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      setup = create_authorization_fixture(messaging, prefix(messaging))

      assert {:ok, %AuthorizationDecision{result: :allow} = invocation} =
               messaging.authorize(
                 setup.controller.id,
                 :invoke_agent,
                 %{setup.thread_scope | target_principal_id: setup.agent.id}
               )

      assert invocation.grant_id == setup.controller_grant.id
      assert invocation.invocation_policy_id == setup.policy.id
      assert invocation.grant_revision == 1
      assert invocation.invocation_policy_revision == 1

      assert {:error, {:authorization_denied, :no_matching_grant, denied}} =
               messaging.authorize(
                 setup.other.id,
                 :invoke_agent,
                 %{setup.thread_scope | target_principal_id: setup.agent.id}
               )

      assert denied.result == :deny

      assert {:ok, %AuthorizationDecision{result: :allow}} =
               messaging.authorize(setup.agent.id, :receive_message, setup.thread_scope)

      assert {:ok, %AuthorizationDecision{constraints: %{"max_results" => 25}}} =
               messaging.authorize(setup.agent.id, :post_message, setup.thread_scope)

      room_scope = AuthorizationScope.new(%{kind: :room, room_id: setup.room.id})

      assert {:error, {:authorization_denied, :no_matching_grant, _decision}} =
               messaging.authorize(setup.agent.id, :post_message, room_scope)

      assert {:ok, human_grant} =
               messaging.create_principal_grant(%{
                 principal_id: setup.other.id,
                 issuer_principal_id: "host-admin",
                 actions: [:receive_message],
                 scope: setup.thread_scope
               })

      assert human_grant.principal_id == setup.other.id

      assert {:ok, %AuthorizationDecision{result: :allow}} =
               messaging.authorize(setup.other.id, :receive_message, setup.thread_scope)
    end
  end

  test "revocation, expiry, and optimistic revisions deny stale authority" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      setup = create_authorization_fixture(messaging, "#{prefix(messaging)}-revision")

      assert {:ok, revoked} =
               messaging.revoke_principal_grant(setup.agent_grant.id, setup.agent_grant.revision)

      assert revoked.status == :revoked
      assert revoked.revision == 2

      assert {:error, {:stale_revision, 2}} =
               messaging.revise_principal_grant(setup.agent_grant.id, 1, %{
                 actions: [:post_message]
               })

      assert {:error, :authorization_revocation_terminal} =
               messaging.revise_principal_grant(setup.agent_grant.id, 2, %{status: :active})

      assert {:error, {:authorization_denied, :no_matching_grant, _decision}} =
               messaging.authorize(setup.agent.id, :post_message, setup.thread_scope)

      assert {:ok, expired} =
               messaging.create_principal_grant(%{
                 principal_id: setup.agent.id,
                 issuer_principal_id: "host-admin",
                 actions: [:read_transcript],
                 scope: %{
                   kind: :transcript,
                   room_id: setup.room.id,
                   thread_id: setup.thread.id
                 },
                 expires_at: DateTime.add(DateTime.utc_now(), -30, :second)
               })

      assert expired.status == :active

      assert {:error, {:authorization_denied, :no_matching_grant, _decision}} =
               messaging.authorize(setup.agent.id, :read_transcript, expired.scope)

      assert {:ok, revoked_policy} =
               messaging.revoke_invocation_policy(setup.policy.id, setup.policy.revision)

      assert revoked_policy.revision == 2

      assert {:error, {:authorization_denied, :invocation_policy_required, _decision}} =
               messaging.authorize(
                 setup.controller.id,
                 :invoke_agent,
                 %{setup.thread_scope | target_principal_id: setup.agent.id}
               )
    end
  end

  test "invocation modes are revisioned and use durable membership" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      setup = create_authorization_fixture(messaging, "#{prefix(messaging)}-modes")

      assert {:ok, other_grant} =
               messaging.create_principal_grant(%{
                 principal_id: setup.other.id,
                 issuer_principal_id: "host-admin",
                 actions: [:invoke_agent],
                 scope: %{setup.thread_scope | target_principal_id: setup.agent.id}
               })

      assert other_grant.revision == 1
      assert_policy_denied(messaging, setup.other.id, setup.agent.id, setup.thread_scope)

      assert {:ok, controller_policy} =
               messaging.revise_invocation_policy(setup.policy.id, 1, %{
                 mode: :controller_only,
                 controller_principal_id: setup.controller.id,
                 allowed_principal_ids: []
               })

      assert controller_policy.revision == 2
      assert_authorized(messaging, setup.controller.id, setup.agent.id, setup.thread_scope)
      assert_policy_denied(messaging, setup.other.id, setup.agent.id, setup.thread_scope)

      assert {:ok, room_policy} =
               messaging.revise_invocation_policy(controller_policy.id, 2, %{
                 mode: :room_members,
                 controller_principal_id: nil
               })

      assert room_policy.revision == 3
      assert_authorized(messaging, setup.other.id, setup.agent.id, setup.thread_scope)

      assert {:ok, revoked_membership} =
               messaging.transition_membership(setup.other_membership.id, 1, :revoked)

      assert revoked_membership.revision == 2

      assert {:error, {:authorization_denied, :membership_required, _decision}} =
               messaging.authorize(
                 setup.other.id,
                 :invoke_agent,
                 %{setup.thread_scope | target_principal_id: setup.agent.id}
               )

      assert {:ok, anyone_policy} =
               messaging.revise_invocation_policy(room_policy.id, 3, %{mode: :anyone})

      assert anyone_policy.revision == 4
      assert_authorized(messaging, setup.controller.id, setup.agent.id, setup.thread_scope)

      assert {:ok, nobody_policy} =
               messaging.revise_invocation_policy(anyone_policy.id, 4, %{mode: :nobody})

      assert nobody_policy.revision == 5
      assert_policy_denied(messaging, setup.controller.id, setup.agent.id, setup.thread_scope)
    end
  end

  test "membership creation is idempotent and grant revision writes are atomic" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      principal = create_participant(messaging, "#{prefix(messaging)}-race-principal", :agent)
      room = create_room(messaging, "#{prefix(messaging)}-race-room")

      memberships =
        1..20
        |> Task.async_stream(
          fn _index ->
            messaging.create_membership(%{
              principal_id: principal.id,
              room_id: room.id,
              issuer_principal_id: "host-admin"
            })
          end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {:ok, membership}} -> membership end)

      assert memberships |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

      assert {:ok, grant} =
               messaging.create_principal_grant(%{
                 principal_id: principal.id,
                 issuer_principal_id: "host-admin",
                 actions: [:post_message],
                 scope: %{kind: :room, room_id: room.id}
               })

      results =
        [[:post_message, :receive_message], [:post_message, :read_transcript]]
        |> Task.async_stream(
          fn actions -> messaging.revise_principal_grant(grant.id, 1, %{actions: actions}) end,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %{revision: 2}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:stale_revision, 2}}, &1)) == 1
    end
  end

  test "enforced chat actions deny before provider access and legacy mode stays explicit" do
    prefix = "chat-action"
    participant = create_participant(ActionMessaging, "#{prefix}-agent", :agent)
    room = create_room(ActionMessaging, "#{prefix}-room")
    canonical_scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: "auth-main"})

    assert {:ok, _bridge} =
             ActionMessaging.put_bridge_config(%{
               id: "auth-main",
               adapter_module: ActionAdapter,
               opts: %{}
             })

    assert {:ok, _membership} =
             ActionMessaging.create_membership(%{
               principal_id: participant.id,
               room_id: room.id,
               issuer_principal_id: "host-admin"
             })

    provider_scope = Scope.channel("auth-main", :authorization_test, "external-room", actor_id: participant.id)
    policy = Policy.allow([:post_message], actor: participant.id, channel: "external-room")
    target = MessagingTarget.for_room("external-room", bridge_id: "auth-main", channel_type: :authorization_test)
    params = %{target: Map.from_struct(target), text: "bounded"}

    enforced_context =
      ChatActions.context(ActionMessaging, %{},
        scope: provider_scope,
        policy: policy,
        principal_id: participant.id,
        authorization_mode: :enforce,
        authorization_scope: canonical_scope
      )

    assert {:ok, %{status: :denied, code: :authorization_denied}} =
             Jido.Exec.run(PostMessage, params, enforced_context)

    refute_received {:authorized_provider_call, _room_id, _payload, _opts}

    assert {:ok, grant} =
             ActionMessaging.create_principal_grant(%{
               principal_id: participant.id,
               issuer_principal_id: "host-admin",
               actions: [:post_message],
               scope: canonical_scope
             })

    assert {:ok, %{status: :ok, audit: %{authorization_mode: :enforce}}} =
             Jido.Exec.run(PostMessage, params, enforced_context)

    assert_receive {:authorized_provider_call, "external-room", _payload, _opts}

    assert {:ok, _read_grant} =
             ActionMessaging.create_principal_grant(%{
               principal_id: participant.id,
               issuer_principal_id: "host-admin",
               actions: [:fetch_channel_messages],
               scope: canonical_scope,
               constraints: %{max_results: 2}
             })

    assert {:ok, %{status: :ok}} =
             Jido.Exec.run(
               FetchChannelMessages,
               %{target: Map.from_struct(target), limit: 20},
               enforced_context
             )

    assert_receive {:authorized_read_call, "external-room", read_opts}
    assert read_opts[:limit] == 2

    assert {:ok, _revoked} = ActionMessaging.revoke_principal_grant(grant.id, 1)

    assert {:ok, %{status: :denied, code: :authorization_denied}} =
             Jido.Exec.run(PostMessage, params, enforced_context)

    refute_received {:authorized_provider_call, _room_id, _payload, _opts}

    legacy_context =
      ChatActions.context(ActionMessaging, %{},
        scope: provider_scope,
        policy: policy,
        principal_id: participant.id,
        authorization_mode: :legacy
      )

    assert {:ok, %{status: :ok, audit: %{authorization_mode: :legacy}}} =
             Jido.Exec.run(PostMessage, params, legacy_context)

    assert_receive {:authorized_provider_call, "external-room", _payload, _opts}
  end

  test "SQLite restores current memberships, grants, and invocation policy revisions" do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido-messaging-authorization-restart-#{System.unique_integer([:positive])}.sqlite3"
      )

    room = Room.new(%{id: "restart-room", type: :group})
    principal = Participant.new(%{id: "restart-principal", type: :human})
    target = Participant.new(%{id: "restart-agent", type: :agent})
    membership = Membership.new(%{principal_id: principal.id, room_id: room.id, issuer_principal_id: "admin"})
    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

    grant =
      Grant.new(%{
        principal_id: principal.id,
        issuer_principal_id: "admin",
        actions: [:invoke_agent],
        scope: %{scope | target_principal_id: target.id}
      })

    policy =
      InvocationPolicy.new(%{
        target_principal_id: target.id,
        issuer_principal_id: "admin",
        scope: scope,
        mode: :allowlist,
        allowed_principal_ids: [principal.id]
      })

    {:ok, state} = SQLite.init(path: path, instance_id: "authorization-restart")
    assert {:ok, ^room} = SQLite.save_room(state, room)
    assert {:ok, ^principal} = SQLite.save_participant(state, principal)
    assert {:ok, ^target} = SQLite.save_participant(state, target)
    assert {:ok, ^membership} = SQLite.save_membership(state, membership)
    assert {:ok, ^grant} = SQLite.save_principal_grant(state, grant)
    assert {:ok, ^policy} = SQLite.save_invocation_policy(state, policy)
    :ok = Sqlite3.close(state.db)

    {:ok, restored} = SQLite.init(path: path, instance_id: "authorization-restart")
    assert {:ok, ^membership} = SQLite.get_membership(restored, membership.id)
    assert {:ok, ^grant} = SQLite.get_principal_grant(restored, grant.id)
    assert {:ok, ^policy} = SQLite.get_invocation_policy(restored, policy.id)
    :ok = Sqlite3.close(restored.db)
    File.rm(path)
  end

  test "authorization records reject runtime controls and secret data" do
    assert_raise ArgumentError, ~r/cannot contain access_token/, fn ->
      Grant.new(%{
        principal_id: "agent",
        issuer_principal_id: "admin",
        actions: [:post_message],
        scope: %{kind: :room, room_id: "room"},
        metadata: %{access_token: "secret"}
      })
    end

    assert_raise ArgumentError, ~r/unsupported grant constraint/, fn ->
      Grant.new(%{
        principal_id: "agent",
        issuer_principal_id: "admin",
        actions: [:post_message],
        scope: %{kind: :room, room_id: "room"},
        constraints: %{tool_controls: %{allow: true}}
      })
    end

    assert_raise ArgumentError, ~r/unsupported messaging authorization action/, fn ->
      Grant.new(%{
        principal_id: "agent",
        issuer_principal_id: "admin",
        actions: [:run_jidoka_tool],
        scope: %{kind: :room, room_id: "room"}
      })
    end
  end

  defp create_authorization_fixture(messaging, prefix) do
    controller = create_participant(messaging, "#{prefix}-controller", :human)
    other = create_participant(messaging, "#{prefix}-other", :human)
    agent = create_participant(messaging, "#{prefix}-agent", :agent)
    room = create_room(messaging, "#{prefix}-room")
    thread = create_thread(messaging, "#{prefix}-thread", room.id)

    controller_membership = create_membership(messaging, controller.id, room.id)
    other_membership = create_membership(messaging, other.id, room.id)
    _agent_membership = create_membership(messaging, agent.id, room.id)
    thread_scope = AuthorizationScope.new(%{kind: :thread, room_id: room.id, thread_id: thread.id})

    {:ok, controller_grant} =
      messaging.create_principal_grant(%{
        principal_id: controller.id,
        issuer_principal_id: "host-admin",
        actions: [:invoke_agent],
        scope: %{thread_scope | target_principal_id: agent.id}
      })

    {:ok, agent_grant} =
      messaging.create_principal_grant(%{
        principal_id: agent.id,
        issuer_principal_id: "host-admin",
        actions: [:receive_message, :post_message],
        scope: thread_scope,
        constraints: %{max_results: 25}
      })

    {:ok, policy} =
      messaging.create_invocation_policy(%{
        target_principal_id: agent.id,
        issuer_principal_id: "host-admin",
        scope: %{kind: :room, room_id: room.id},
        mode: :allowlist,
        allowed_principal_ids: [controller.id]
      })

    %{
      controller: controller,
      other: other,
      agent: agent,
      room: room,
      thread: thread,
      controller_membership: controller_membership,
      other_membership: other_membership,
      thread_scope: thread_scope,
      controller_grant: controller_grant,
      agent_grant: agent_grant,
      policy: policy
    }
  end

  defp create_participant(messaging, id, type) do
    {:ok, participant} = messaging.create_participant(%{id: id, type: type})
    participant
  end

  defp create_room(messaging, id) do
    {:ok, room} = messaging.create_room(%{id: id, type: :group})
    room
  end

  defp create_thread(messaging, id, room_id) do
    {:ok, thread} = messaging.save_thread(%{id: id, room_id: room_id})
    thread
  end

  defp create_membership(messaging, principal_id, room_id) do
    {:ok, membership} =
      messaging.create_membership(%{
        principal_id: principal_id,
        room_id: room_id,
        issuer_principal_id: "host-admin"
      })

    membership
  end

  defp assert_authorized(messaging, principal_id, target_id, scope) do
    assert {:ok, %AuthorizationDecision{result: :allow}} =
             messaging.authorize(principal_id, :invoke_agent, %{scope | target_principal_id: target_id})
  end

  defp assert_policy_denied(messaging, principal_id, target_id, scope) do
    assert {:error, {:authorization_denied, :invocation_policy_denied, _decision}} =
             messaging.authorize(principal_id, :invoke_agent, %{scope | target_principal_id: target_id})
  end

  defp prefix(ETSMessaging), do: "ets"
  defp prefix(SQLiteMessaging), do: "sqlite"
end
