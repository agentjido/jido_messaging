defmodule Jido.Messaging.IdentityCallbackOutcomeTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.Participant
  alias Jido.Messaging.{ExternalIdentityBinding, Identity, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    @controlled [
      :get_principal,
      :save_principal,
      :get_external_identity_binding,
      :save_external_identity_binding,
      :list_external_identity_bindings
    ]
    for {name, arity} <- ETS.__info__(:functions), name not in @controlled do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def get_principal(state, id), do: call(:principal_read, fn -> ETS.get_principal(state, id) end)
    def save_principal(state, record), do: call(:principal_save, fn -> ETS.save_principal(state, record) end)

    def get_external_identity_binding(state, id),
      do: call(:binding_read, fn -> ETS.get_external_identity_binding(state, id) end)

    def get_external_identity_binding(state, channel, bridge, id),
      do: call(:scope_read, fn -> ETS.get_external_identity_binding(state, channel, bridge, id) end)

    def save_external_identity_binding(state, record),
      do: call(:binding_save, fn -> ETS.save_external_identity_binding(state, record) end)

    def list_external_identity_bindings(state, id, opts),
      do: call(:binding_list, fn -> ETS.list_external_identity_bindings(state, id, opts) end)

    defp call(operation, fun) do
      mode =
        Agent.get_and_update(__MODULE__.Control, fn state ->
          {Map.get(state.modes, operation, :pass), %{state | calls: Map.update(state.calls, operation, 1, &(&1 + 1))}}
        end)

      case mode do
        :pass ->
          fun.()

        {:after_write, mode} ->
          result = fun.()
          Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1})
          fail(mode, result)

        mode ->
          fail(mode, nil)
      end
    end

    defp fail(:error, _), do: {:error, :identity_store_unavailable}
    defp fail(:raise, _), do: raise("private identity store")
    defp fail(:throw, _), do: throw(:private_identity_store)
    defp fail(:exit, _), do: exit(:private_identity_store)
    defp fail(:invalid, _), do: :invalid
    defp fail(:invalid_record, _), do: {:ok, %{id: "invalid"}}
    defp fail({:result, result}, _), do: result
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
    participant = Participant.new(%{id: "owned", type: :human})
    foreign_participant = Participant.new(%{id: "foreign", type: :human})
    for person <- [participant, foreign_participant], do: assert({:ok, person} == ETS.save_participant(state, person))
    {:ok, principal} = ETS.get_principal(state, "owned")
    {:ok, foreign_principal} = ETS.get_principal(state, "foreign")
    binding = binding(principal, "owned-bridge")
    foreign_binding = binding(foreign_principal, "foreign-bridge")

    for selected <- [binding, foreign_binding],
        do: assert({:ok, selected} == ETS.save_external_identity_binding(state, selected))

    {:ok,
     runtime: runtime,
     state: state,
     participant: participant,
     principal: principal,
     binding: binding,
     foreign_principal: foreign_principal,
     foreign_binding: foreign_binding}
  end

  for operation <- [:principal_read, :principal_save, :binding_read, :scope_read, :binding_save, :binding_list],
      mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record] do
    test "#{operation} #{mode} callback returns a safe failure and preserves owned/foreign identity", context do
      set_mode(unquote(operation), unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = operation(unquote(operation), context)
      assert_records(context, context.principal, context.binding)
    end
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "binding #{mode} after-write keeps one complete strengthening and no principal promotion", context do
      set_mode(:binding_save, {:after_write, unquote(mode)})
      expected = expected(unquote(mode))

      assert {:error, ^expected} =
               Instance.bind_external_identity("owned", :test, "owned-bridge", "provider",
                 assurance: :provider_verified,
                 proof_ref: "proof:complete"
               )

      assert Agent.get(Store.Control, & &1.writes) == 1
      assert {:ok, saved} = ETS.get_external_identity_binding(context.state, context.binding.id)
      assert saved.assurance == :provider_verified
      assert saved.proof_ref == "proof:complete"
      assert_records(context, context.principal, saved)
      set_mode(:binding_save, :pass)

      assert {:ok, ^saved} =
               Instance.bind_external_identity("owned", :test, "owned-bridge", "provider",
                 assurance: :provider_verified,
                 proof_ref: "proof:complete"
               )

      assert {:ok, promoted} = ETS.get_principal(context.state, "owned")
      assert promoted.verification_state == :verified
      assert_foreign(context)
    end

    test "principal promotion #{mode} after-write retains the exact confirmed assurance without false success",
         context do
      set_mode(:principal_save, {:after_write, unquote(mode)})
      expected = expected(unquote(mode))

      assert {:error, ^expected} =
               Instance.bind_external_identity("owned", :test, "owned-bridge", "provider",
                 assurance: :provider_verified
               )

      assert Agent.get(Store.Control, & &1.writes) == 1
      assert {:ok, promoted} = ETS.get_principal(context.state, "owned")
      assert promoted.verification_state == :verified
      assert {:ok, saved} = ETS.get_external_identity_binding(context.state, context.binding.id)
      assert saved.assurance == :provider_verified
      assert_records(context, promoted, saved)
    end
  end

  test "foreign and partial identity results cannot replace canonical scope", context do
    for {operation, result} <- [
          {:principal_read, {:ok, context.foreign_principal}},
          {:principal_save, {:ok, context.foreign_principal}},
          {:binding_read, {:ok, context.foreign_binding}},
          {:scope_read, {:ok, %{context.binding | bridge_id: "foreign"}}},
          {:binding_save, {:ok, context.foreign_binding}},
          {:binding_list, {:ok, [context.binding, context.foreign_binding]}},
          {:binding_list, {:ok, [context.binding, nil]}}
        ] do
      set_mode(operation, {:result, result})
      assert {:error, :persistence_failed} = operation(operation, context)
      assert_records(context, context.principal, context.binding)
      set_mode(operation, :pass)
    end
  end

  test "principal projection read failure cannot return a foreign principal for the participant", context do
    set_mode(:principal_read, {:result, {:ok, context.foreign_principal}})
    assert {:error, :persistence_failed} = Identity.ensure_principal(Store, context.state, context.participant)
    assert_records(context, context.principal, context.binding)
  end

  test "a foreign scoped read cannot strengthen another bridge or promote the principal", context do
    set_mode(:scope_read, {:result, {:ok, %{context.binding | bridge_id: "foreign"}}})

    assert {:error, :persistence_failed} =
             Instance.bind_external_identity("owned", :test, "owned-bridge", "provider", assurance: :provider_verified)

    assert Agent.get(Store.Control, &Map.get(&1.calls, :binding_save, 0)) == 0
    assert Agent.get(Store.Control, &Map.get(&1.calls, :principal_save, 0)) == 0
    assert_records(context, context.principal, context.binding)
  end

  test "failed authorship binding write returns no authorship or false principal promotion", context do
    set_mode(:binding_save, :error)
    verification = %{metadata: %{identity_assurance: :provider_verified, identity_proof_ref: "proof:complete"}}

    assert {:error, :identity_store_unavailable} =
             Identity.resolve_authorship(
               Store,
               context.state,
               context.participant,
               :test,
               "owned-bridge",
               "provider",
               verification
             )

    assert Agent.get(Store.Control, &Map.get(&1.calls, :principal_save, 0)) == 0
    assert_records(context, context.principal, context.binding)
  end

  defp operation(:principal_read, context), do: Instance.get_principal(context.principal.id)

  defp operation(:principal_save, context),
    do: Instance.save_principal(%{context.principal | metadata: %{complete: "update"}})

  defp operation(:binding_read, context), do: Instance.get_external_identity_binding(context.binding.id)
  defp operation(:scope_read, _context), do: Instance.get_external_identity_binding(:test, "owned-bridge", "provider")
  defp operation(:binding_save, context), do: Instance.revoke_external_identity_binding(context.binding.id)
  defp operation(:binding_list, context), do: Instance.list_external_identity_bindings(context.principal.id)
  defp set_mode(operation, mode), do: Agent.update(Store.Control, &%{&1 | modes: Map.put(&1.modes, operation, mode)})
  defp expected(:error), do: :identity_store_unavailable
  defp expected(_), do: :persistence_failed

  defp binding(principal, bridge),
    do:
      ExternalIdentityBinding.new(%{
        principal_id: principal.id,
        participant_id: principal.id,
        channel: :test,
        bridge_id: bridge,
        external_id: "provider",
        metadata: %{complete: bridge}
      })

  defp assert_records(context, principal, binding) do
    assert {:ok, ^principal} = ETS.get_principal(context.state, "owned")
    assert {:ok, ^binding} = ETS.get_external_identity_binding(context.state, context.binding.id)
    assert_foreign(context)
  end

  defp assert_foreign(context) do
    assert {:ok, foreign} = ETS.get_principal(context.state, "foreign")
    assert foreign == context.foreign_principal
    assert {:ok, binding} = ETS.get_external_identity_binding(context.state, context.foreign_binding.id)
    assert binding == context.foreign_binding
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert :ets.info(context.state.messages, :size) == 0
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert Instance.count_agents() == 0
  end
end
