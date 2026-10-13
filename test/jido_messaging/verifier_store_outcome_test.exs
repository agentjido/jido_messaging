defmodule Jido.Messaging.VerifierStoreOutcomeTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{IdentityCredential, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    @controlled [:get_participant, :get_room, :get_identity_credential, :consume_identity_assertion]
    for {name, arity} <- ETS.__info__(:functions), name not in @controlled do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def get_participant(state, id), do: call(:participant, fn -> ETS.get_participant(state, id) end)
    def get_room(state, id), do: call(:room, fn -> ETS.get_room(state, id) end)
    def get_identity_credential(state, id), do: call(:credential, fn -> ETS.get_identity_credential(state, id) end)

    def consume_identity_assertion(state, id, key, expiry),
      do: call(:assertion, fn -> ETS.consume_identity_assertion(state, id, key, expiry) end)

    defp call(operation, fun) do
      case Agent.get(__MODULE__.Control, &Map.get(&1, operation, :pass)) do
        :pass ->
          fun.()

        {:after_write, mode} ->
          :ok = fun.()
          fail(mode)

        mode ->
          fail(mode)
      end
    end

    defp fail(:error), do: {:error, :verification_store_unavailable}
    defp fail(:raise), do: raise("private verification store")
    defp fail(:throw), do: throw(:private_verification_store)
    defp fail(:exit), do: exit(:private_verification_store)
    defp fail(:invalid), do: :invalid
    defp fail(:invalid_record), do: {:ok, %{id: "invalid"}}
    defp fail({:result, result}), do: result
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Provider do
    @behaviour Jido.Messaging.IdentityProvider
    @impl true
    def verify(_credential, _proof, _context, opts) do
      send(opts[:notify], :proof_provider_called)
      {:ok, %{assurance: :verified, metadata: %{complete: "safe"}}}
    end
  end

  setup do
    start_supervised!(%{id: Store.Control, start: {Agent, :start_link, [fn -> %{} end, [name: Store.Control]]}})
    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)

    for id <- ["issuer", "subject", "foreign"] do
      participant = Participant.new(%{id: id, type: :human})
      assert {:ok, ^participant} = ETS.save_participant(state, participant)
    end

    room = Room.new(%{id: "owned-room", type: :group})
    assert {:ok, ^room} = ETS.save_room(state, room)
    now = DateTime.utc_now()

    credential =
      IdentityCredential.new(%{
        id: "owned",
        issuer_principal_id: "issuer",
        subject_principal_id: "subject",
        provider_id: "fixture",
        proof_type: "opaque",
        proof_ref: "proof:complete",
        conditions: %{audience: "fixture", room_ids: [room.id]},
        issued_at: now,
        not_before: now,
        expires_at: DateTime.add(now, 3_600, :second)
      })

    assert {:ok, ^credential} = ETS.save_identity_credential(state, credential)

    proof = %{
      assertion_id: "assertion",
      proof_type: credential.proof_type,
      proof_ref: credential.proof_ref,
      issued_at: DateTime.utc_now()
    }

    scope = %{subject_principal_id: "subject", controller_principal_id: "issuer", audience: "fixture", room_id: room.id}
    {:ok, runtime: runtime, state: state, credential: credential, proof: proof, scope: scope, room: room}
  end

  for operation <- [:credential, :participant, :room],
      mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record] do
    test "#{operation} #{mode} read rejects before proof provider and replay write", context do
      set_mode(unquote(operation), unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = verify(context)
      refute_received :proof_provider_called
      assert :ets.info(context.state.identity_assertions, :size) == 0
      assert_preserved(context)
    end
  end

  for operation <- [:participant, :room], mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record] do
    test "uncredentialed #{operation} #{mode} read cannot produce lower-assurance evidence", context do
      set_mode(unquote(operation), unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = Instance.verify_optional_identity(nil, %{}, context.scope)
      refute_received :proof_provider_called
      assert :ets.info(context.state.identity_assertions, :size) == 0
      assert_preserved(context)
    end
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "assertion #{mode} failure returns no evidence after one proof callback", context do
      set_mode(:assertion, unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = verify(context)
      assert_received :proof_provider_called
      refute_received :proof_provider_called
      assert :ets.info(context.state.identity_assertions, :size) == 0
      assert_preserved(context)
    end

    test "assertion #{mode} after-write failure retains one consumed marker and cannot verify replay", context do
      set_mode(:assertion, {:after_write, unquote(mode)})
      expected = expected(unquote(mode))
      assert {:error, ^expected} = verify(context)
      assert_received :proof_provider_called
      assert :ets.info(context.state.identity_assertions, :size) == 1
      set_mode(:assertion, :pass)
      assert {:error, :identity_assertion_replayed} = verify(context)
      assert_received :proof_provider_called
      assert :ets.info(context.state.identity_assertions, :size) == 1
      assert_preserved(context)
    end
  end

  test "foreign credential, participant and room read results cannot supply verification authority", context do
    for {op, result} <- [
          {:credential, %{context.credential | id: "foreign"}},
          {:participant, Participant.new(%{id: "foreign", type: :human})},
          {:room, %{context.room | id: "foreign"}}
        ] do
      set_mode(op, {:result, {:ok, result}})
      assert {:error, :persistence_failed} = verify(context)
      refute_received :proof_provider_called
      assert :ets.info(context.state.identity_assertions, :size) == 0
      set_mode(op, :pass)
    end

    assert_preserved(context)
  end

  defp verify(context),
    do: Instance.verify_identity_credential("owned", context.proof, context.scope, provider: Provider, notify: self())

  defp set_mode(op, mode), do: Agent.update(Store.Control, &Map.put(&1, op, mode))
  defp expected(:error), do: :verification_store_unavailable
  defp expected(_), do: :persistence_failed

  defp assert_preserved(context) do
    assert {:ok, credential} = ETS.get_identity_credential(context.state, "owned")
    assert credential == context.credential
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert :ets.info(context.state.messages, :size) == 0
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert Instance.count_agents() == 0
  end
end
