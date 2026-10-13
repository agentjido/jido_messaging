defmodule Jido.Messaging.ReadReceiptCallbackOutcomeTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{AuthorizationScope, Message, ReadReceipt, Runtime}
  alias Jido.Messaging.Persistence.ETS
  alias Jido.Messaging.Signal.MarkAsRead

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name != :mark_message_read do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def mark_message_read(state, id, participant, receipt) do
      {mode, foreign} =
        Agent.get_and_update(Control, fn data ->
          {{data.mode, data.foreign}, %{data | attempts: data.attempts + 1}}
        end)

      case mode do
        {:before, failure} ->
          fail(failure)

        {:after, failure} ->
          {:ok, _, _} = write(state, id, participant, receipt)
          fail(failure)

        :foreign ->
          {:ok, foreign, :updated}

        :incomplete ->
          {:ok, message} = ETS.get_message(state, id)
          {:ok, message, :updated}

        :invalid_change ->
          {:ok, message} = ETS.get_message(state, id)
          {updated, _} = ReadReceipt.apply_to_message(message, participant, receipt)
          {:ok, updated, :unknown}

        :pass ->
          write(state, id, participant, receipt)
      end
    end

    defp write(state, id, participant, receipt) do
      result = ETS.mark_message_read(state, id, participant, receipt)
      Agent.update(Control, &%{&1 | writes: &1.writes + 1})
      result
    end

    defp fail(:error), do: {:error, :private_store_unavailable}
    defp fail(:raise), do: raise("private receipt store")
    defp fail(:throw), do: throw(:private_receipt_store)
    defp fail(:exit), do: exit(:private_receipt_store)
    defp fail(:invalid), do: {:ok, :private_receipt_store}
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    def channel_type, do: :receipt_outcome
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])

    def mark_as_read(room, message, _opts) do
      Agent.update(Control, &%{&1 | provider_calls: &1.provider_calls ++ [{room, message}]})
      :ok
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{
      id: Control,
      start:
        {Agent, :start_link,
         [fn -> %{mode: :pass, foreign: nil, attempts: 0, writes: 0, provider_calls: []} end, [name: Control]]}
    })

    start_supervised!(Instance)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "receipt-bridge")
    runtime = Instance.__jido_messaging__(:runtime)
    :ok = Runtime.register_binding(runtime, binding)

    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:receipt_outcome, binding.id, "provider-room", %{type: :group})

    {:ok, foreign_room} = Instance.create_room(%{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, message} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: [Jido.Chat.Content.Text.new("complete content")],
        external_id: "provider-message",
        status: :sent,
        metadata: %{bridge_id: binding.id, retained: "metadata"}
      })

    {:ok, foreign} =
      Instance.save_message(%{
        room_id: foreign_room.id,
        sender_id: participant.id,
        role: :user,
        content: [Jido.Chat.Content.Text.new("foreign content")],
        external_id: "provider-message",
        status: :sent
      })

    Agent.update(Control, &%{&1 | foreign: foreign})
    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:receive_message],
        scope: scope,
        constraints: %{requires_membership: false}
      })

    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.read")

    request =
      MarkAsRead.new!(%{
        "request_id" => "read-once",
        "room_id" => room.id,
        "message_id" => message.id,
        "bridge_id" => binding.id,
        "read_at" => "2026-08-20T12:00:00Z"
      })

    {:ok,
     runtime: runtime,
     message: message,
     foreign: foreign,
     participant: participant,
     binding: binding,
     request: request,
     actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  for phase <- [:before, :after], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{failure} #{phase} receipt write retains exact state and cannot repeat provider", context do
      Agent.update(Control, &%{&1 | mode: {unquote(phase), unquote(failure)}})
      before = Jido.Signal.to_map(context.request)
      assert {:ok, failed} = Instance.execute(context.request, context.actor)
      assert failed.type == "jido.messaging.operation.failed"
      assert failed.data["code"] == "persistence_failed"
      assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
      assert Jido.Signal.to_map(context.request) == before
      assert Jido.Signal.Context.get(failed, "causationid") == context.request.id
      assert_counts(context, if(unquote(phase) == :after, do: 1, else: 0))
      assert_records(context, unquote(phase) == :after)
      refute_receive {:signal, _}
    end
  end

  for mode <- [:foreign, :incomplete, :invalid_change] do
    test "#{mode} success cannot claim a persisted receipt", context do
      Agent.update(Control, &%{&1 | mode: unquote(mode)})
      assert {:ok, failed} = Instance.execute(context.request, context.actor)
      assert failed.type == "jido.messaging.operation.failed"
      assert failed.data["code"] == "persistence_failed"
      assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
      assert_counts(context, 0)
      assert_records(context, false)
      refute_receive {:signal, _}
    end
  end

  test "provider confirmation saves one complete receipt and emits one causal fact", context do
    assert {:ok, completed} = Instance.execute(context.request, context.actor)
    assert completed.type == "jido.messaging.operation.completed"
    assert {:ok, ^completed} = Instance.execute(context.request, context.actor)
    assert_counts(context, 1)
    assert_records(context, true)
    assert_receive {:signal, fact}
    assert fact.type == "jido.messaging.message.read"
    assert fact.data["message_id"] == context.message.id
    assert Jido.Signal.Context.get(fact, "causationid") == context.request.id
    refute_receive {:signal, _}
  end

  defp assert_counts(context, writes) do
    data = Agent.get(Control, & &1)
    assert data.provider_calls == [{"provider-room", "provider-message"}]
    assert data.attempts == 1
    assert data.writes == writes
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 1
  end

  defp assert_records(context, written) do
    expected =
      if written do
        receipt = %{
          bridge_id: context.binding.id,
          external_message_id: context.message.external_id,
          read_at: ~U[2026-08-20 12:00:00Z]
        }

        {updated, :updated} = ReadReceipt.apply_to_message(context.message, context.participant.id, receipt)
        updated
      else
        context.message
      end

    assert {:ok, %Message{} = actual} = Instance.get_message(context.message.id)
    assert actual == expected
    assert {:ok, foreign} = Instance.get_message(context.foreign.id)
    assert foreign == context.foreign
    assert Instance.count_agents() == 0
    {_store, state} = Runtime.get_persistence(context.runtime)
    assert :ets.info(state.memberships, :size) == 0
  end
end
