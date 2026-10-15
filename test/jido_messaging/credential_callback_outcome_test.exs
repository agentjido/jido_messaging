defmodule Jido.Messaging.CredentialCallbackOutcomeTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{IdentityCredential, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    @controlled [
      :get_participant,
      :get_room,
      :get_identity_credential,
      :list_identity_credentials,
      :save_identity_credential,
      :rotate_identity_credential
    ]
    for {name, arity} <- ETS.__info__(:functions), name not in @controlled do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def get_participant(state, id), do: call(:participant, fn -> ETS.get_participant(state, id) end)
    def get_room(state, id), do: call(:room, fn -> ETS.get_room(state, id) end)
    def get_identity_credential(state, id), do: call(:get, fn -> ETS.get_identity_credential(state, id) end)

    def list_identity_credentials(state, id, opts),
      do: call(:list, fn -> ETS.list_identity_credentials(state, id, opts) end)

    def save_identity_credential(state, record), do: call(:save, fn -> ETS.save_identity_credential(state, record) end)

    def rotate_identity_credential(state, old, next),
      do: call(:rotate, fn -> ETS.rotate_identity_credential(state, old, next) end)

    defp call(operation, fun) do
      mode =
        Agent.get_and_update(__MODULE__.Control, fn state ->
          {Map.get(state.modes, operation, :pass), %{state | calls: Map.update(state.calls, operation, 1, &(&1 + 1))}}
        end)

      case mode do
        :pass ->
          fun.()

        {:after_write, mode} ->
          _ = fun.()
          Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1})
          fail(mode)

        mode ->
          fail(mode)
      end
    end

    defp fail(:error), do: {:error, :credential_store_unavailable}
    defp fail(:raise), do: raise("private credential store")
    defp fail(:throw), do: throw(:private_credential_store)
    defp fail(:exit), do: exit(:private_credential_store)
    defp fail(:invalid), do: :invalid
    defp fail(:invalid_record), do: {:ok, %{id: "invalid"}}
    defp fail({:result, value}), do: value
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{modes: %{}, calls: %{}, writes: 0} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)

    for id <- ["issuer", "subject", "foreign"] do
      person = Participant.new(%{id: id, type: :human})
      assert {:ok, ^person} = ETS.save_participant(state, person)
    end

    room = Room.new(%{id: "owned-room", type: :group})
    assert {:ok, ^room} = ETS.save_room(state, room)
    attrs = attrs("owned", "subject")
    original = IdentityCredential.new(attrs)
    foreign = IdentityCredential.new(attrs("foreign", "foreign"))
    for record <- [original, foreign], do: assert({:ok, record} == ETS.save_identity_credential(state, record))
    {:ok, runtime: runtime, state: state, attrs: attrs, original: original, foreign: foreign, room: room}
  end

  for operation <- [:participant, :room, :get, :list, :save, :rotate],
      failure <- [:error, :raise, :throw, :exit, :invalid, :invalid_record] do
    test "#{operation} #{failure} result is a safe failure with no credential or authority change", context do
      set_mode(unquote(operation), unquote(failure))
      expected = expected(unquote(failure))
      assert {:error, ^expected} = operation(unquote(operation), context)
      assert_records(context)
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "transition #{failure} after-write retains one confirmed revision and rejects stale retry", context do
      set_mode(:save, {:after_write, unquote(failure)})
      expected = expected(unquote(failure))
      assert {:error, ^expected} = Instance.suspend_identity_credential("owned", 1)
      assert Agent.get(Store.Control, & &1.writes) == 1
      assert {:ok, stored} = ETS.get_identity_credential(context.state, "owned")
      assert stored.status == :suspended and stored.revision == 2
      set_mode(:save, :pass)
      assert {:error, {:stale_revision, 2}} = Instance.suspend_identity_credential("owned", 1)
      assert Agent.get(Store.Control, & &1.writes) == 1
      assert_foreign(context)
    end

    test "rotation #{failure} after-write retains both complete records without a successful response", context do
      set_mode(:rotate, {:after_write, unquote(failure)})
      expected = expected(unquote(failure))
      assert {:error, ^expected} = Instance.rotate_identity_credential("owned", 1, replacement())
      assert Agent.get(Store.Control, & &1.writes) == 1
      assert {:ok, revoked} = ETS.get_identity_credential(context.state, "owned")
      assert revoked.status == :revoked and revoked.revision == 2
      assert {:ok, next} = ETS.get_identity_credential(context.state, "replacement")
      assert next.rotated_from_credential_id == "owned"
      assert next.subject_principal_id == "subject"
      assert next.proof_ref == "proof:replacement"
      assert next.metadata == %{complete: "replacement"}
      set_mode(:rotate, :pass)
      assert {:error, {:stale_revision, 2}} = Instance.rotate_identity_credential("owned", 1, replacement())
      assert_foreign(context)
    end
  end

  test "foreign reads and a partial invalid list cannot return owned credential data", context do
    for {op, result} <- [
          {:participant, {:ok, Participant.new(%{id: "foreign", type: :human})}},
          {:room, {:ok, %{context.room | id: "foreign"}}},
          {:get, {:ok, context.foreign}},
          {:list, {:ok, [context.original, context.foreign]}},
          {:list, {:ok, [context.original, nil]}}
        ] do
      set_mode(op, {:result, result})
      assert {:error, :persistence_failed} = operation(op, context)
      assert_records(context)
      set_mode(op, :pass)
    end
  end

  test "rotation cannot accept a different returned subject or proof", context do
    revoked = IdentityCredential.transition(context.original, :revoked, reason: "rotated")

    next =
      IdentityCredential.new(
        Map.merge(replacement(), %{
          issuer_principal_id: "issuer",
          subject_principal_id: "subject",
          conditions: context.original.conditions,
          rotated_from_credential_id: "owned"
        })
      )

    for invalid <- [%{next | subject_principal_id: "foreign"}, %{next | proof_ref: "different"}] do
      set_mode(:rotate, {:result, {:ok, revoked, invalid}})
      assert {:error, :persistence_failed} = Instance.rotate_identity_credential("owned", 1, replacement())
      assert_records(context)
    end
  end

  defp operation(op, context) when op in [:participant, :room],
    do: Instance.create_identity_credential(Map.put(context.attrs, :id, "new"))

  defp operation(:get, _), do: Instance.get_identity_credential("owned")
  defp operation(:list, _), do: Instance.list_identity_credentials("subject")
  defp operation(:save, _), do: Instance.suspend_identity_credential("owned", 1)
  defp operation(:rotate, _), do: Instance.rotate_identity_credential("owned", 1, replacement())
  defp set_mode(op, mode), do: Agent.update(Store.Control, &%{&1 | modes: Map.put(&1.modes, op, mode)})
  defp expected(:error), do: :credential_store_unavailable
  defp expected(_), do: :persistence_failed

  defp replacement,
    do: Map.drop(attrs("replacement", "subject"), [:issuer_principal_id, :subject_principal_id, :conditions])

  defp attrs(id, subject) do
    now = DateTime.utc_now()

    %{
      id: id,
      issuer_principal_id: "issuer",
      subject_principal_id: subject,
      provider_id: "fixture",
      proof_type: "opaque",
      proof_ref: "proof:" <> id,
      conditions: %{audience: "fixture", room_ids: ["owned-room"]},
      issued_at: now,
      not_before: now,
      expires_at: DateTime.add(now, 3_600, :second),
      metadata: %{complete: id}
    }
  end

  defp assert_records(context) do
    assert {:ok, owned} = ETS.get_identity_credential(context.state, "owned")
    assert owned == context.original
    assert {:error, :not_found} = ETS.get_identity_credential(context.state, "replacement")
    assert {:error, :not_found} = ETS.get_identity_credential(context.state, "new")
    assert_foreign(context)
  end

  defp assert_foreign(context) do
    assert {:ok, foreign} = ETS.get_identity_credential(context.state, "foreign")
    assert foreign == context.foreign
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert :ets.info(context.state.identity_assertions, :size) == 0
    assert Jido.Messaging.TestHelpers.runtime_entry_count(context.runtime) == 0
    assert Instance.count_agents() == 0
  end
end
