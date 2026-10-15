defmodule Jido.Messaging.TranscriptIdentityFailureTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.Persistence.ETS

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name != :list_external_identity_bindings do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def list_external_identity_bindings(state, principal, opts) do
      case Process.get(:binding_read_result, :pass) do
        :pass -> ETS.list_external_identity_bindings(state, principal, opts)
        :raise -> raise "binding store failed"
        :throw -> throw(:binding_store_failed)
        :exit -> exit(:binding_store_failed)
        other -> other
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "room", type: :group})

    {:ok, person} =
      Instance.create_participant(%{id: "person", type: :human, external_ids: %{slack: "other-bridge-user"}})

    {:ok, binding} = Instance.bind_external_identity(person.id, :slack, "correct-bridge", "correct-user")

    {:ok, message} =
      Instance.save_message(%{
        id: "legacy",
        room_id: room.id,
        sender_id: person.id,
        role: :user,
        metadata: %{channel: :slack, bridge_id: "correct-bridge"}
      })

    {:ok, scope} = Instance.history_scope([room.id])
    {:ok, person: person, binding: binding, message: message, scope: scope}
  end

  test "typed lookup succeeds with its scoped provider identity", context do
    assert {:ok, [entry]} = Instance.participant_transcript(context.person.id, context.scope)
    assert entry.provider_participant_id == "correct-user"
    assert entry.external_identity_binding_id == context.binding.id
  end

  for failure <- [{:error, :store_unavailable}, :raise, :throw, :exit, :invalid, {:ok, [nil]}] do
    test "#{inspect(failure)} typed lookup cannot select a channel-wide identity", context do
      Process.put(:binding_read_result, unquote(Macro.escape(failure)))
      assert {:ok, [entry]} = Instance.participant_transcript(context.person.id, context.scope)
      assert entry.provider_participant_id == nil
      assert entry.external_identity_binding_id == nil
      assert entry.canonical_participant_id == context.person.id
      assert entry.message == context.message
      assert {:ok, binding} = Instance.get_external_identity_binding(context.binding.id)
      assert binding == context.binding
    end
  end

  for result <- [{:error, :unsupported}, {:ok, []}] do
    test "#{inspect(result)} retains the absent or unsupported legacy fallback", context do
      Process.put(:binding_read_result, unquote(Macro.escape(result)))
      assert {:ok, [entry]} = Instance.participant_transcript(context.person.id, context.scope)
      assert entry.provider_participant_id == "other-bridge-user"
    end
  end
end
