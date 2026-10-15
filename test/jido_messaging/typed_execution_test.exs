defmodule Jido.Messaging.TypedExecutionTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Messaging.{AuthorizationScope, Events, Runtime}
  alias Jido.Messaging.Signal.{Identity, PostMessage, SendMessage}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Blocking do
    def signal_protocol, do: 1
    def channel_type, do: :test
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(_binding, _input), do: {:error, :invalid_delivery}
    def capabilities, do: %{send_message: :native}

    def send_message(room, text, opts) do
      send(opts[:notify], {:provider_started, self()})

      receive do
        :release -> {:ok, %{"id" => "message", "room_id" => room, "text" => text}}
      end
    end
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "execution-binding", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)

    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:test, binding.id, "provider-room", %{type: :group, name: "Room"})

    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, _} =
      Instance.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})

    {:ok, grant} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message, :fetch_channel_messages],
        scope: scope
      })

    {:ok, binding: binding, transport: transport, room: room, participant: participant, grant: grant, scope: scope}
  end

  defp request(context, overrides \\ %{}) do
    SendMessage.new!(
      Map.merge(
        %{"request_id" => "one", "room_id" => context.room.id, "bridge_id" => context.binding.id, "text" => "hello"},
        overrides
      )
    )
  end

  defp actor(context), do: [principal_id: context.participant.id, authorization_scope: context.scope]

  test "one selected provider callback returns a typed runtime result", context do
    parent = request(context)
    before = Jido.Signal.to_map(parent)
    assert {:ok, result} = Instance.execute(parent, actor(context))
    assert result.type == "jido.messaging.operation.completed"
    assert result.data["operation"] == "provider.send_message"
    assert result.source == Events.source(Instance)
    assert result.subject == Identity.room_subject(context.room.id)
    assert Jido.Signal.Context.get(result, "causationid") == parent.id
    assert Jido.Signal.Trace.get(result).trace_id == Jido.Signal.Trace.get(parent).trace_id
    assert Jido.Signal.to_map(parent) == before

    assert [%{operation: :send_message, payload: %{room_id: "provider-room", text: "hello"}}] =
             MockTransport.calls(context.transport)

    assert {:ok, ^result} = Instance.execute(parent, actor(context))
    assert length(MockTransport.calls(context.transport)) == 1
  end

  test "Signal source and data do not supply the trusted actor", context do
    assert {:ok, denied} = Instance.execute(request(context), [])
    assert denied.type == "jido.messaging.operation.failed"
    assert denied.data["code"] == "authorization_denied"
    assert MockTransport.calls(context.transport) == []
  end

  test "exact replay and grant revocation survive cache eviction and store recovery", context do
    parent = request(context)
    assert {:ok, %{type: "jido.messaging.operation.completed"} = original} = Instance.execute(parent, actor(context))
    runtime = Instance.__jido_messaging__(:runtime)
    runtime_pid = Process.whereis(runtime)
    table = Runtime.request_table(runtime)

    for index <- 1..1_001 do
      {:ok, claim} = Jido.Messaging.RequestLedger.claim(table, {:eviction, index}, :payload, :authority)
      :ok = Jido.Messaging.RequestLedger.complete(table, claim, index)
    end

    [{Jido.Messaging.RequestStore, store}] = :ets.lookup(table, Jido.Messaging.RequestStore)
    {:ok, stat} = Jido.Messaging.RequestStore.call(store, :stats)
    Process.exit(stat.worker, :kill)

    Jido.Messaging.TestHelpers.assert_eventually(
      fn ->
        case Jido.Messaging.RequestStore.call(store, :stats) do
          {:ok, %{worker: worker}} -> worker != stat.worker
          _ -> false
        end
      end,
      timeout: 2_000
    )

    assert {:ok, ^original} = Instance.execute(parent, actor(context))
    assert Process.whereis(runtime) == runtime_pid
    assert {:ok, _} = Instance.revoke_principal_grant(context.grant.id, context.grant.revision)
    assert {:ok, denied} = Instance.execute(parent, actor(context))
    assert denied.data["code"] == "authorization_denied"
    assert length(MockTransport.calls(context.transport)) == 1
  end

  test "canonical scope mismatch causes zero provider calls", context do
    scope = %{context.scope | room_id: "other-room"}

    assert {:ok, denied} =
             Instance.execute(request(context), principal_id: context.participant.id, authorization_scope: scope)

    assert denied.data["code"] == "authorization_denied"
    assert MockTransport.calls(context.transport) == []
  end

  test "a runtime post persists once and returns a native result", context do
    parent =
      PostMessage.new!(%{
        "request_id" => "post",
        "room_id" => context.room.id,
        "sender_id" => context.participant.id,
        "text" => "local"
      })

    assert {:ok, result} = Instance.execute(parent, actor(context))
    assert result.type == "jido.messaging.operation.completed"
    assert {:ok, message} = Instance.get_message(result.data["result"]["id"])
    assert message.content |> hd() |> Map.fetch!(:text) == "local"
    assert {:ok, ^result} = Instance.execute(parent, actor(context))
    assert {:ok, [_one]} = Instance.list_messages(context.room.id)
    assert MockTransport.calls(context.transport) == []
  end

  test "a sender ID claim cannot replace the trusted principal", context do
    parent =
      PostMessage.new!(%{
        "request_id" => "post",
        "room_id" => context.room.id,
        "sender_id" => "other-participant",
        "text" => "local"
      })

    assert {:ok, denied} = Instance.execute(parent, actor(context))
    assert denied.data["code"] == "authorization_denied"
    assert {:ok, []} = Instance.list_messages(context.room.id)
    assert MockTransport.calls(context.transport) == []
  end

  test "failed observation does not repeat an admitted provider operation", context do
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Module.concat(Instance, SignalBus))

    {id, ^bus, _kind, _modules} =
      Enum.find(Supervisor.which_children(supervisor), fn {_id, pid, _kind, _modules} -> pid == bus end)

    :ok = Supervisor.terminate_child(supervisor, id)
    parent = request(context)
    assert {:ok, failed} = Instance.execute(parent, actor(context))
    assert failed.data["code"] == "observation_failed"
    assert {:ok, ^failed} = Instance.execute(parent, actor(context))
    assert length(MockTransport.calls(context.transport)) == 1
  end

  test "publication of a runtime post cannot repeat the committed write", context do
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Module.concat(Instance, SignalBus))

    {id, ^bus, _kind, _modules} =
      Enum.find(Supervisor.which_children(supervisor), fn {_id, pid, _kind, _modules} -> pid == bus end)

    :ok = Supervisor.terminate_child(supervisor, id)

    parent =
      PostMessage.new!(%{
        "request_id" => "post",
        "room_id" => context.room.id,
        "sender_id" => context.participant.id,
        "text" => "local"
      })

    assert {:ok, failed} = Instance.execute(parent, actor(context))
    assert failed.data["code"] == "observation_failed"
    assert {:ok, ^failed} = Instance.execute(parent, actor(context))
    assert {:ok, [_one]} = Instance.list_messages(context.room.id)
    assert MockTransport.calls(context.transport) == []
  end

  test "authorization store failure causes zero provider callbacks", context do
    {_persistence, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    :ets.insert(state.principal_grants, {"invalid", self()})
    assert {:ok, failed} = Instance.execute(request(context), actor(context))
    assert failed.data["code"] == "authorization_store_failed"
    assert MockTransport.calls(context.transport) == []
  end

  test "query constraints apply with and without an explicit limit", context do
    assert {:ok, _} =
             Instance.revise_principal_grant(context.grant.id, context.grant.revision, %{constraints: %{max_results: 2}})

    for {id, limit} <- [{"explicit", 20}, {"implicit", nil}] do
      data = %{
        "request_id" => id,
        "room_id" => context.room.id,
        "bridge_id" => context.binding.id,
        "direction" => "backward",
        "cursor" => "before-one"
      }

      data = if limit, do: Map.put(data, "limit", limit), else: data
      assert {:ok, result} = Instance.execute(Jido.Messaging.Signal.FetchChannelMessages.new!(data), actor(context))
      assert result.type == "jido.messaging.operation.completed"
    end

    assert [%{payload: %{opts: opts1}}, %{payload: %{opts: opts2}}] = MockTransport.calls(context.transport)
    assert opts1[:limit] == 2
    assert opts2[:limit] == 2
    assert opts1[:direction] == :backward
    assert opts2[:direction] == :backward
    assert opts1[:cursor] == "before-one"
    assert opts2[:cursor] == "before-one"
  end

  test "private policy can narrow a durable grant", context do
    policy = Jido.Messaging.ChatActions.Policy.default()
    assert {:ok, denied} = Instance.execute(request(context), Keyword.put(actor(context), :policy, policy))
    assert denied.data["code"] == "authorization_denied"
    assert MockTransport.calls(context.transport) == []

    allowed =
      Jido.Messaging.ChatActions.Policy.allow([:post_message],
        actor: context.participant.id,
        bridge_id: context.binding.id
      )

    assert {:ok, result} = Instance.execute(request(context), Keyword.put(actor(context), :policy, allowed))
    assert result.type == "jido.messaging.operation.completed"
    assert length(MockTransport.calls(context.transport)) == 1
  end

  test "an invalid private policy denies the request before a provider call", context do
    assert {:ok, denied} = Instance.execute(request(context), Keyword.put(actor(context), :policy, :invalid))
    assert denied.data["code"] == "authorization_denied"
    assert MockTransport.calls(context.transport) == []
  end

  test "a thread from another canonical room cannot select a provider target", context do
    {:ok, other} = Instance.create_room(%{type: :group})
    {:ok, thread} = Instance.save_thread(%{room_id: other.id, external_thread_id: "private-thread"})
    assert {:ok, denied} = Instance.execute(request(context, %{"thread_id" => thread.id}), actor(context))
    assert denied.data["code"] == "authorization_denied"
    assert MockTransport.calls(context.transport) == []
  end

  test "in-flight requests cannot start a second callback", context do
    {:ok, binding} = Jido.Chat.bind(Blocking, id: context.binding.id, notify: self())
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    parent = request(context)
    actor = actor(context)
    worker = Task.async(fn -> Instance.execute(parent, actor) end)
    assert_receive {:provider_started, owner}
    assert {:error, %Jido.Chat.Errors.Contract{code: :request_in_progress}} = Instance.execute(parent, actor)
    refute_receive {:provider_started, _}, 0
    send(owner, :release)
    assert {:ok, completed} = Task.await(worker)
    assert {:ok, ^completed} = Instance.execute(parent, actor)
    refute_receive {:provider_started, _}, 0
  end

  test "a terminated caller leaves an unknown outcome and does not call again", context do
    {:ok, binding} = Jido.Chat.bind(Blocking, id: context.binding.id, notify: self())
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    parent = request(context)
    actor = actor(context)
    {owner, monitor} = spawn_monitor(fn -> Instance.execute(parent, actor) end)
    assert_receive {:provider_started, ^owner}
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert {:error, %Jido.Chat.Errors.Contract{code: :request_outcome_unknown}} = Instance.execute(parent, actor)
    refute_receive {:provider_started, _}, 0
  end

  test "private failure classes retain runtime retry decisions without exposing provider details", context do
    for {reason, class} <- [
          {:timeout, :recoverable},
          {%{class: :degraded, token: "private-token"}, :degraded},
          {:invalid_request, :fatal}
        ] do
      :ok = MockTransport.stub(context.transport, :send_message, [{:error, reason}])
      id = Atom.to_string(class)

      assert {:error, private} =
               Jido.Messaging.AdapterBridge.operation(
                 MockAdapter,
                 :send_message,
                 %{"room_id" => "provider-room", "text" => "hello"},
                 binding: context.binding,
                 request_id: id
               )

      assert Jido.Messaging.AdapterBridge.classify_failure(private) == class
      assert {:ok, result} = Instance.execute(request(context, %{"request_id" => "runtime-" <> id}), actor(context))
      assert result.type == "jido.messaging.operation.completed"
    end

    :ok = MockTransport.stub(context.transport, :send_message, [{:error, :timeout}])
    parent = request(context, %{"request_id" => "retryable"})
    assert {:ok, failure} = Instance.execute(parent, actor(context))
    assert failure.data["retryable"] == true
    assert failure.data["code"] == "provider_failure"
    refute Jason.encode!(Jido.Signal.to_map(failure)) =~ "private-token"
    count = length(MockTransport.calls(context.transport))
    assert {:ok, ^failure} = Instance.execute(parent, actor(context))
    assert length(MockTransport.calls(context.transport)) == count
  end

  test "the tool context cannot select a legacy authorization bypass", context do
    {:ok, _} = Instance.put_bridge_config(%{id: context.binding.id, adapter_module: MockAdapter})
    scope = Jido.Messaging.ChatActions.Scope.channel(context.binding.id, :test, "provider-room")
    policy = Jido.Messaging.ChatActions.Policy.allow([:post_message])

    actor_context =
      Jido.Messaging.ChatActions.context(Instance, %{}, scope: scope, policy: policy, authorization_mode: :legacy)

    params = %{target: %{instance_id: context.binding.id, external_id: "provider-room"}, text: "hello"}
    assert {:ok, denied} = Jido.Messaging.ChatActions.Executor.execute(:post_message, params, actor_context)
    assert denied.type == "jido.messaging.operation.failed"
    assert denied.data["code"] == "authorization_denied"
    assert MockTransport.calls(context.transport) == []
  end

  test "same request identity with different content is a conflict", context do
    assert {:ok, _} = Instance.execute(request(context), actor(context))

    assert {:error, %Jido.Chat.Errors.Contract{code: :request_conflict}} =
             Instance.execute(request(context, %{"text" => "other"}), actor(context))

    assert length(MockTransport.calls(context.transport)) == 1
  end
end

defmodule Jido.Messaging.TypedProviderOperationMatrixTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.AdapterTestKit.Factories
  alias Jido.Messaging.{AuthorizationAction, AuthorizationScope, Runtime}

  @operations Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/operations.json")
              |> File.read!()
              |> Jason.decode!()
              |> Map.fetch!("operations")
  @results Map.new(@operations, &{String.to_atom(&1["operation"]), &1["result_fixture"]})

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Native do
    @callbacks [
      send_message: 3,
      send_file: 3,
      post_message: 3,
      edit_message: 4,
      delete_message: 3,
      start_typing: 2,
      fetch_metadata: 2,
      fetch_thread: 2,
      fetch_message: 3,
      get_user: 2,
      fetch_subject: 2,
      get_thread_participants: 2,
      mark_as_read: 3,
      fetch_media: 2,
      add_reaction: 4,
      remove_reaction: 4,
      post_ephemeral: 4,
      post_channel_message: 3,
      stream: 3,
      open_modal: 3,
      load_options: 2,
      fetch_messages: 2,
      fetch_channel_messages: 2,
      list_threads: 2,
      open_thread: 3,
      open_dm: 2
    ]
    def signal_protocol, do: 1
    def channel_type, do: :test
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(_binding, _input), do: {:error, :invalid_delivery}
    def capabilities, do: Map.new(@callbacks, fn {operation, _arity} -> {operation, :native} end)

    for {operation, arity} <- @callbacks do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(args)) do
        arguments = [unquote_splicing(args)]
        opts = List.last(arguments)
        send(opts[:notify], {:provider_call, unquote(operation), arguments})

        case opts[:mode] do
          :failure ->
            {:error, :network_error}

          _ ->
            if unquote(operation) == :fetch_media,
              do: {:ok, <<255, 1>>},
              else: {:ok, opts[:results][unquote(operation)]}
        end
      end
    end
  end

  defmodule Unsupported do
    def signal_protocol, do: 1
    def channel_type, do: :test
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(_binding, _input), do: {:error, :invalid_delivery}

    def capabilities,
      do:
        Map.new(Jido.Chat.Operations.Definitions.all(), fn {_type, {_module, op, _fields, _shape, _schema}} ->
          {op, :unsupported}
        end)
  end

  setup do
    start_supervised!(Instance)
    {:ok, binding} = Jido.Chat.bind(Native, id: "matrix", notify: self(), results: @results)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, room} = Instance.get_or_create_room_by_external_binding(:test, binding.id, "room/1", %{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, _} =
      Instance.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    room_scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})
    bridge_scope = AuthorizationScope.new(%{kind: :bridge, bridge_id: binding.id})

    for scope <- [room_scope, bridge_scope] do
      {:ok, _} =
        Instance.create_principal_grant(%{
          principal_id: participant.id,
          issuer_principal_id: "host",
          actions: AuthorizationAction.all(),
          scope: scope,
          constraints: %{requires_membership: false}
        })
    end

    {:ok, binding: binding, room: room, principal: participant.id, room_scope: room_scope, bridge_scope: bridge_scope}
  end

  defp runtime_request(context, row) do
    operation = String.to_atom(row["operation"])

    if operation == :mark_as_read do
      {:ok, _} =
        Instance.save_message(%{
          id: "message-1",
          room_id: context.room.id,
          sender_id: context.principal,
          role: :user,
          content: [Jido.Chat.Content.Text.new("hello")],
          external_id: "message-1",
          metadata: %{bridge_id: context.binding.id}
        })
    end

    chat = Factories.operation_request(context.binding, operation)
    name = row["request_module"] |> String.replace("Jido.Chat.Signal.", "Jido.Messaging.Signal.")
    name = if operation == :post_message, do: "Jido.Messaging.Signal.PostProviderMessage", else: name
    data = Map.put(chat.data, "bridge_id", context.binding.id)
    data = if data["room_id"], do: Map.put(data, "room_id", context.room.id), else: data
    scope = if data["room_id"], do: context.room_scope, else: context.bridge_scope
    {Module.concat([name]).new!(data), [principal_id: context.principal, authorization_scope: scope]}
  end

  test "resource expiry, cancellation, and failure return typed results without a callback", context do
    for {state, code} <- [
          {:expired, "resource_expired"},
          {:cancelled, "resource_cancelled"},
          {:failed, "resource_failure"}
        ] do
      opts = if state == :expired, do: [ttl_ms: 0], else: []

      {:ok, ref} =
        Jido.Chat.put_resource(context.binding, "file", Jido.Chat.FileUpload.new(%{data: "private-bytes"}), opts)

      if state == :cancelled, do: :ok = Jido.Chat.cancel_resource(context.binding, ref)
      if state == :failed, do: :ok = Jido.Chat.Resources.fail(context.binding, ref)

      request =
        Jido.Messaging.Signal.SendFile.new!(%{
          "request_id" => code,
          "bridge_id" => context.binding.id,
          "room_id" => context.room.id,
          "resource_ref" => ref
        })

      actor = [principal_id: context.principal, authorization_scope: context.room_scope]
      assert {:ok, failed} = Instance.execute(request, actor)
      assert failed.data["code"] == code
      assert {:ok, ^failed} = Instance.execute(request, actor)
      refute_received {:provider_call, _, _}
    end
  end

  test "a resource belongs to its call owner and cannot run from another process", context do
    {:ok, ref} = Jido.Chat.put_resource(context.binding, "file", Jido.Chat.FileUpload.new(%{data: "private-bytes"}))

    request =
      Jido.Messaging.Signal.SendFile.new!(%{
        "request_id" => "owner",
        "bridge_id" => context.binding.id,
        "room_id" => context.room.id,
        "resource_ref" => ref
      })

    actor = [principal_id: context.principal, authorization_scope: context.room_scope]
    task = Task.async(fn -> Instance.execute(request, actor) end)
    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_owner_mismatch}} = Task.await(task)
    refute_received {:provider_call, _, _}
  end

  test "large result references retain all query items and the cursor", context do
    page = %{
      "messages" => [%{"id" => "large", "room_id" => "room/1", "text" => String.duplicate("x", 300_000)}],
      "next_cursor" => "next-page",
      "complete" => false
    }

    results = Map.put(@results, :fetch_channel_messages, page)
    {:ok, binding} = Jido.Chat.bind(Native, id: context.binding.id, notify: self(), results: results)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)

    request =
      Jido.Messaging.Signal.FetchChannelMessages.new!(%{
        "request_id" => "large",
        "bridge_id" => binding.id,
        "room_id" => context.room.id
      })

    actor = [principal_id: context.principal, authorization_scope: context.room_scope]
    assert {:ok, result} = Instance.execute(request, actor)
    assert result.type == "jido.messaging.operation.completed"
    assert {:ok, ^page} = Jido.Chat.resolve_resource(binding, result.data["result"]["resource_ref"])
    assert {:ok, ^result} = Instance.execute(request, actor)
    assert_received {:provider_call, :fetch_channel_messages, _}
    refute_received {:provider_call, _, _}
    assert byte_size(Jason.encode!(Jido.Signal.to_map(result))) <= 262_144
  end

  for row <- @operations do
    test "#{row["operation"]}: unsupported runtime selection calls no provider", context do
      row = unquote(Macro.escape(row))
      {:ok, binding} = Jido.Chat.bind(Unsupported, id: context.binding.id)
      :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
      context = %{context | binding: binding}
      {request, opts} = runtime_request(context, row)
      assert {:ok, failed} = Instance.execute(request, opts)
      assert failed.data["code"] == "unsupported"
      assert failed.data["retryable"] == false
      assert {:ok, ^failed} = Instance.execute(request, opts)
      refute_received {:provider_call, _, _}
    end

    test "#{row["operation"]}: provider failure is typed and not repeated", context do
      row = unquote(Macro.escape(row))
      {:ok, binding} = Jido.Chat.bind(Native, id: context.binding.id, notify: self(), mode: :failure)
      :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
      context = %{context | binding: binding}
      {request, opts} = runtime_request(context, row)
      assert {:ok, failed} = Instance.execute(request, opts)
      assert failed.data["code"] == "provider_failure"
      assert failed.data["retryable"] == true
      assert {:ok, ^failed} = Instance.execute(request, opts)
      operation = String.to_atom(row["operation"])
      assert_received {:provider_call, ^operation, _}
      refute_received {:provider_call, _, _}
      assert {:ok, encoded} = Jido.Signal.Serialization.serialize(failed)
      {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
      assert {:ok, ^failed} = Jido.Signal.Catalog.decode(catalog, encoded)
    end

    test "#{row["operation"]}: runtime authorization selects one typed provider callback", context do
      row = unquote(Macro.escape(row))
      operation = String.to_atom(row["operation"])
      chat_request = Factories.operation_request(context.binding, operation)

      if operation == :mark_as_read do
        {:ok, _} =
          Instance.save_message(%{
            id: "message-1",
            room_id: context.room.id,
            sender_id: context.principal,
            role: :user,
            content: [Jido.Chat.Content.Text.new("hello")],
            external_id: "message-1",
            metadata: %{bridge_id: context.binding.id}
          })
      end

      module_name = row["request_module"] |> String.replace("Jido.Chat.Signal.", "Jido.Messaging.Signal.")
      module_name = if operation == :post_message, do: "Jido.Messaging.Signal.PostProviderMessage", else: module_name
      module = Module.concat([module_name])
      data = Map.put(chat_request.data, "bridge_id", context.binding.id)
      data = if data["room_id"], do: Map.put(data, "room_id", context.room.id), else: data
      scope = if data["room_id"], do: context.room_scope, else: context.bridge_scope
      request = module.new!(data)
      assert {:ok, result} = Instance.execute(request, principal_id: context.principal, authorization_scope: scope)
      assert result.type == "jido.messaging.operation.completed"
      assert result.data["operation"] == "provider." <> row["operation"]
      assert_received {:provider_call, ^operation, args}
      assert length(args) == row["callback"]["arity"]
      refute_received {:provider_call, _, _}
      assert {:ok, encoded} = Jido.Signal.Serialization.serialize(result)
      {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
      assert {:ok, ^result} = Jido.Signal.Catalog.decode(catalog, encoded)
    end
  end
end

defmodule Jido.Messaging.TypedRuntimeOperationMatrixTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{AuthorizationAction, AuthorizationScope, RoomServer, RoomSupervisor, Runtime}

  defmodule FailingPersistence do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- Jido.Messaging.Persistence.ETS.__info__(:functions), name != :save_message do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: Jido.Messaging.Persistence.ETS
    end

    def save_message(state, message) do
      case :ets.lookup(state.rooms, :save_failure) do
        [{:save_failure, true}] -> {:error, :store_unavailable}
        [] -> Jido.Messaging.Persistence.ETS.save_message(state, message)
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging,
      persistence: Jido.Messaging.TypedRuntimeOperationMatrixTest.FailingPersistence,
      runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{type: :group, name: "Room"})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, _} =
      Instance.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: AuthorizationAction.all(),
        scope: scope
      })

    {:ok, server} = RoomSupervisor.get_or_start_room(Instance, room)
    :ok = RoomServer.add_participant(server, participant)

    {:ok, message} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: [Jido.Chat.Content.Text.new("hello")]
      })

    :ok = RoomServer.add_message(server, message)

    {:ok,
     room: room,
     participant: participant,
     message: message,
     server: server,
     actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  @operations [
    {Jido.Messaging.Signal.ParticipantJoinedRequest, "participant_joined"},
    {Jido.Messaging.Signal.ParticipantLeftRequest, "participant_left"},
    {Jido.Messaging.Signal.SetPresence, "set_presence"},
    {Jido.Messaging.Signal.SetTyping, "set_typing"},
    {Jido.Messaging.Signal.AddRoomReaction, "add_room_reaction"},
    {Jido.Messaging.Signal.RemoveRoomReaction, "remove_room_reaction"},
    {Jido.Messaging.Signal.MarkDelivered, "mark_delivered"},
    {Jido.Messaging.Signal.MarkRead, "mark_read"}
  ]
  for {definition, operation} <- @operations do
    test "#{operation}: registered runtime request keeps record ownership", context do
      module = unquote(definition)
      operation = unquote(operation)
      data = %{"request_id" => operation, "room_id" => context.room.id, "participant_id" => context.participant.id}

      data =
        case operation do
          "set_presence" ->
            Map.put(data, "presence", "away")

          "set_typing" ->
            Map.put(data, "typing", true)

          op when op in ["add_room_reaction", "remove_room_reaction"] ->
            Map.merge(data, %{"message_id" => context.message.id, "reaction" => "👍"})

          op when op in ["mark_delivered", "mark_read"] ->
            Map.put(data, "message_id", context.message.id)

          _ ->
            data
        end

      request = module.new!(data)
      assert {:ok, result} = Instance.execute(request, context.actor)
      assert result.type == "jido.messaging.operation.completed"
      assert result.data["operation"] == operation
      assert result.data["result"] == %{"acknowledged" => true}
      assert {:ok, ^result} = Instance.execute(request, context.actor)
      assert {:ok, encoded} = Jido.Signal.Serialization.serialize(result)
      {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
      assert {:ok, ^result} = Jido.Signal.Catalog.decode(catalog, encoded)
    end
  end

  test "a committed room change has the request as its direct trace parent", context do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.reaction_added")

    request =
      Jido.Messaging.Signal.AddRoomReaction.new!(%{
        "request_id" => "reaction-parent",
        "room_id" => context.room.id,
        "participant_id" => context.participant.id,
        "message_id" => context.message.id,
        "reaction" => "👍"
      })

    assert {:ok, _} = Instance.execute(request, context.actor)
    assert_receive {:signal, fact}
    assert Jido.Signal.Context.get(fact, "causationid") == request.id
    assert Jido.Signal.Trace.get(fact).trace_id == Jido.Signal.Trace.get(request).trace_id
    assert {:ok, stored} = Instance.get_message(context.message.id)
    assert stored.reactions["👍"] == [context.participant.id]

    assert {:ok, _} =
             Instance.execute(%{request | data: Map.put(request.data, "request_id", "same-reaction")}, context.actor)

    refute_receive {:signal, _}
  end

  test "a store failure leaves room history and fact counts unchanged", context do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.reaction_added")
    runtime = Instance.__jido_messaging__(:runtime)
    {_adapter, state} = Runtime.get_persistence(runtime)
    :ets.insert(state.rooms, {:save_failure, true})

    request =
      Jido.Messaging.Signal.AddRoomReaction.new!(%{
        "request_id" => "failed-store",
        "room_id" => context.room.id,
        "participant_id" => context.participant.id,
        "message_id" => context.message.id,
        "reaction" => "👍"
      })

    assert {:ok, failed} = Instance.execute(request, context.actor)
    assert failed.data["code"] == "persistence_failed"
    assert {:ok, ^failed} = Instance.execute(request, context.actor)
    assert RoomServer.get_messages(context.server) == [context.message]
    assert {:ok, stored} = Instance.get_message(context.message.id)
    assert stored.reactions == %{}
    refute_receive {:signal, _}
  end

  test "a canonical message outside bounded room history still has one committed receipt", context do
    {:ok, message} =
      Instance.save_message(%{
        room_id: context.room.id,
        sender_id: context.participant.id,
        role: :user,
        content: [Jido.Chat.Content.Text.new("older message")]
      })

    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.read")

    request =
      Jido.Messaging.Signal.MarkRead.new!(%{
        "request_id" => "read-stored",
        "room_id" => context.room.id,
        "participant_id" => context.participant.id,
        "message_id" => message.id
      })

    assert {:ok, _} = Instance.execute(request, context.actor)
    assert_receive {:signal, fact}
    assert Jido.Signal.Context.get(fact, "causationid") == request.id
    assert {:ok, stored} = Instance.get_message(message.id)
    assert stored.receipts[context.participant.id][:read_at] != nil

    assert {:ok, _} =
             Instance.execute(%{request | data: Map.put(request.data, "request_id", "read-again")}, context.actor)

    refute_receive {:signal, _}
  end

  test "room creation is a typed operation under a trusted bridge scope", context do
    scope = AuthorizationScope.new(%{kind: :bridge, bridge_id: "host-bridge"})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: context.participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope,
        constraints: %{requires_membership: false}
      })

    request = Jido.Messaging.Signal.CreateRoom.new!(%{"request_id" => "create", "name" => "Created", "kind" => "group"})
    assert {:ok, result} = Instance.execute(request, principal_id: context.participant.id, authorization_scope: scope)
    assert result.type == "jido.messaging.operation.completed"
    assert {:ok, room} = Instance.get_room(result.data["result"]["id"])
    assert room.name == "Created"
    assert room.type == :group
    assert {:ok, ^result} = Instance.execute(request, principal_id: context.participant.id, authorization_scope: scope)
    assert {:ok, rooms} = Instance.list_rooms()
    assert length(rooms) == 2
  end
end
