defmodule Jido.Messaging.ExecutionAdmissionFailureTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.{AuthorizationAction, AuthorizationScope, Events, Runtime}
  alias Jido.Messaging.Signal.{Identity, SendMessage}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :test
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
    @impl true
    def capabilities, do: %{send_message: :native}

    @impl true
    def send_message(room, text, opts) do
      :ok = MockTransport.request(opts[:transport], :send_message, %{room: room, text: text}, :ok)

      case opts[:mode] do
        :raise -> raise "private provider detail"
        :throw -> throw({:private, "provider detail"})
        :exit -> exit({:private, "provider detail"})
        :invalid -> {:ok, %{id: nil, token: "private provider detail"}}
        :unsafe -> {:ok, %{id: "sent", text: self()}}
        :error -> {:error, {:network_error, "private provider detail"}}
        :complete -> {:ok, %{id: "sent", text: text, token: "private provider detail", raw: self()}}
      end
    end
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "execution-admission", transport: transport)
    runtime = Instance.__jido_messaging__(:runtime)
    :ok = Runtime.register_binding(runtime, binding)
    {:ok, room} = Instance.get_or_create_room_by_external_binding(:test, binding.id, "external-room", %{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})
    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})

    {:ok, _grant} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: AuthorizationAction.all(),
        scope: scope,
        constraints: %{requires_membership: false}
      })

    {:ok, runtime: runtime, binding: binding, transport: transport, room: room, participant: participant, scope: scope}
  end

  test "malformed requests and invalid context have no admission or provider effect", context do
    request = request(context)
    {:ok, event} = Events.room_event(Instance, :room_created, context.room.id, %{name: "Room", kind: "group"})

    for invalid <- [
          nil,
          %{},
          event,
          %{request | id: String.duplicate("a", 129)},
          %{request | subject: Identity.room_subject("foreign")},
          %{request | data: Map.put(request.data, "text", self())},
          %{request | data: Map.put(request.data, "token", "private")},
          %{request | data: Map.put(request.data, "text", String.duplicate("x", 262_144))}
        ] do
      assert {:error, _} = Instance.execute(invalid, actor(context))
      assert_no_admission(context)
    end

    assert {:error, %Contract{code: :invalid_request}} = Instance.execute(request, :invalid_options)
    assert_no_admission(context)
  end

  test "invalid trusted scopes deny before request admission", context do
    for scope <- [nil, %{}, %{kind: :bridge}, %{kind: :room, room_id: context.room.id, message_id: "invalid"}] do
      assert {:ok, failure} =
               Instance.execute(request(context), principal_id: context.participant.id, authorization_scope: scope)

      assert failure.data["code"] == "authorization_denied"
      assert_no_admission(context)
    end
  end

  test "missing provider binding is cached without a provider callback", context do
    :sys.replace_state(context.runtime, &%{&1 | bindings: %{}})
    assert_cached_failure(context, request(context), "persistence_failed")
    assert MockTransport.calls(context.transport) == []
    assert :ets.info(context.binding.resources, :size) == 0
  end

  test "a local thread without a provider identity cannot select a target", context do
    {:ok, thread} = Instance.save_thread(%{room_id: context.room.id})
    assert_cached_failure(context, request(context, %{"thread_id" => thread.id}), "persistence_failed")
    assert MockTransport.calls(context.transport) == []
  end

  for {name, attrs} <- [disabled: %{enabled: false}, inbound: %{direction: :inbound}] do
    test "#{name} room binding cannot fall back to the legacy provider target", context do
      {:ok, [binding]} = Instance.list_room_bindings(context.room.id)
      {_store, state} = Runtime.get_persistence(context.runtime)
      :ets.insert(state.room_bindings_by_id, {binding.id, struct!(binding, unquote(Macro.escape(attrs)))})
      assert {:ok, [stored]} = Instance.list_room_bindings(context.room.id)
      assert Map.take(stored, Map.keys(unquote(Macro.escape(attrs)))) == unquote(Macro.escape(attrs))
      assert_cached_failure(context, request(context), "persistence_failed")
      assert MockTransport.calls(context.transport) == []
    end
  end

  test "a deleted canonical room cannot select a legacy provider target", context do
    {_store, state} = Runtime.get_persistence(context.runtime)
    :ets.delete(state.rooms, context.room.id)
    assert_cached_failure(context, request(context), "persistence_failed")
    assert MockTransport.calls(context.transport) == []
  end

  for {mode, code, retryable} <- [
        {:raise, "provider_failure", true},
        {:throw, "provider_failure", true},
        {:exit, "provider_failure", true},
        {:error, "provider_failure", true},
        {:invalid, "invalid_provider_result", false},
        {:unsafe, "invalid_provider_result", false}
      ] do
    test "#{mode} provider result is safe and cannot repeat the callback", context do
      {:ok, binding} =
        Jido.Chat.bind(Adapter, id: context.binding.id, transport: context.transport, mode: unquote(mode))

      :ok = Runtime.register_binding(context.runtime, binding)
      parent = request(context)
      before = Jido.Signal.to_map(parent)
      result = assert_cached_failure(context, parent, unquote(code))
      assert result.data["retryable"] == unquote(retryable)
      assert Jido.Signal.Context.get(result, "causationid") == parent.id
      assert Jido.Signal.to_map(parent) == before
      refute Jason.encode!(Jido.Signal.to_map(result)) =~ "private provider detail"

      assert [%{operation: :send_message, payload: %{room: "external-room", text: "hello"}}] =
               MockTransport.calls(context.transport)
    end
  end

  test "provider completion preserves full selected text and excludes private result fields", context do
    {:ok, binding} = Jido.Chat.bind(Adapter, id: context.binding.id, transport: context.transport, mode: :complete)
    :ok = Runtime.register_binding(context.runtime, binding)
    text = String.duplicate("complete text ", 10_000)
    parent = request(context, %{"text" => text})
    before = Jido.Signal.to_map(parent)
    assert {:ok, result} = Instance.execute(parent, actor(context))
    assert result.data["result"] == %{"id" => "sent", "room_id" => "external-room", "text" => text}
    assert Jido.Signal.Context.get(result, "causationid") == parent.id
    assert Jido.Signal.to_map(parent) == before
    refute Jason.encode!(Jido.Signal.to_map(result)) =~ "private provider detail"
    assert {:ok, ^result} = Instance.execute(parent, actor(context))
    assert length(MockTransport.calls(context.transport)) == 1
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 1
    assert {:ok, []} = Instance.list_messages(context.room.id)
  end

  defp request(context, overrides \\ %{}) do
    SendMessage.new!(
      Map.merge(
        %{
          "request_id" => "admission-one",
          "bridge_id" => context.binding.id,
          "room_id" => context.room.id,
          "text" => "hello"
        },
        overrides
      )
    )
  end

  defp actor(context), do: [principal_id: context.participant.id, authorization_scope: context.scope]

  defp assert_no_admission(context) do
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert :ets.info(context.binding.resources, :size) == 0
    assert MockTransport.calls(context.transport) == []
    assert {:ok, []} = Instance.list_messages(context.room.id)
  end

  defp assert_cached_failure(context, parent, code) do
    assert {:ok, result} = Instance.execute(parent, actor(context))
    assert result.type == "jido.messaging.operation.failed"
    assert result.data["code"] == code
    assert {:ok, ^result} = Instance.execute(parent, actor(context))
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 1
    assert {:ok, []} = Instance.list_messages(context.room.id)
    result
  end
end
