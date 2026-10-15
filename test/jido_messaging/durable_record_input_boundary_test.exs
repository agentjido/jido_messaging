defmodule Jido.Messaging.DurableRecordInputBoundaryTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{AuthorizationScope, Persistence.ETS}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    @writes [:save_principal_grant, :save_identity_credential, :save_agent_messaging_endpoint]
    for {name, arity} <- ETS.__info__(:functions), name not in @writes do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    for name <- @writes do
      def unquote(name)(state, record) do
        Agent.update(__MODULE__.Control, &(&1 + 1))
        ETS.unquote(name)(state, record)
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{id: Store.Control, start: {Agent, :start_link, [fn -> 0 end, [name: Store.Control]]}})
    start_supervised!(Instance)
    {:ok, _} = Instance.create_participant(%{id: "issuer", type: :human})
    for id <- ["owned", "foreign"], do: assert({:ok, _} = Instance.create_participant(%{id: id, type: :agent}))
    {:ok, room} = Instance.create_room(%{id: "owned-room", type: :group})

    records =
      for kind <- [:grant, :credential, :endpoint], owner <- ["owned", "foreign"] do
        {:ok, record} = create(kind, attrs(kind, owner))
        {kind, record}
      end

    Agent.update(Store.Control, fn _ -> 0 end)
    {:ok, records: records, room: room, runtime: Instance.__jido_messaging__(:runtime)}
  end

  for kind <- [:grant, :credential, :endpoint] do
    test "#{kind} invalid nested metadata cannot write or change an owned or foreign record", context do
      for metadata <- [
            nil,
            [],
            DateTime.utc_now(),
            %{callback: self()},
            %{callback: fn -> :private end},
            %{nested: [%{" ACCESS_TOKEN " => "fixture-secret"}]},
            %{1 => "invalid key"},
            %{nested: [%URI{}]}
          ] do
        reject(unquote(kind), Map.put(attrs(unquote(kind), "owned"), :metadata, metadata))
        assert_unchanged(context)
      end
    end

    test "#{kind} invalid required and optional references cannot write", context do
      fields =
        case unquote(kind) do
          :grant -> [:principal_id, :issuer_principal_id]
          :credential -> [:provider_id, :proof_ref, :key_version_ref]
          :endpoint -> [:principal_id, :availability_ref]
        end

      for field <- fields, value <- [7, "   ", String.duplicate("x", 513)] do
        reject(unquote(kind), Map.put(attrs(unquote(kind), "owned"), field, value))
        assert_unchanged(context)
      end
    end

    test "#{kind} valid nested metadata retains complete values", context do
      metadata = %{"complete" => [nil, true, 1, 1.5, "é", :safe, ~U[2026-08-20 12:00:00Z], %{"nested" => [1, 2]}]}
      input = attrs(unquote(kind), "owned") |> Map.put(:id, "new-#{unquote(kind)}") |> Map.put(:metadata, metadata)

      input =
        if unquote(kind) == :endpoint,
          do: Map.merge(input, %{principal_id: "new", jidoka_agent_ref: %{system: :jidoka, id: "new-agent"}}),
          else: input

      if unquote(kind) == :endpoint, do: assert({:ok, _} = Instance.create_participant(%{id: "new", type: :agent}))

      assert {:ok, record} = create(unquote(kind), input)
      assert record.metadata == metadata
      assert {:ok, ^record} = get(unquote(kind), record.id)
      assert Agent.get(Store.Control, & &1) == 1
      for {kind, original} <- context.records, do: assert({:ok, original} == get(kind, original.id))
      assert_no_communication(context)
    end
  end

  for kind <- [:grant, :credential] do
    test "#{kind} oversized metadata and bounded lists reject before a write", context do
      for metadata <- [%{label: String.duplicate("x", 65_536)}, %{labels: Enum.to_list(1..257)}] do
        reject(unquote(kind), Map.put(attrs(unquote(kind), "owned"), :metadata, metadata))
        assert_unchanged(context)
      end
    end
  end

  test "grant constraint type errors cannot change authority", context do
    for constraints <- [
          nil,
          [],
          %{1 => true},
          %{unknown: 1},
          %{max_results: 0},
          %{max_results: "1"},
          %{requires_membership: "false"}
        ] do
      reject(:grant, Map.put(attrs(:grant, "owned"), :constraints, constraints))
      assert_unchanged(context)
    end
  end

  test "duplicate normalized grant constraints reject before changing authority", context do
    for constraints <- [
          %{:requires_membership => true, "requires_membership" => false},
          %{:max_results => 1, " MAX_RESULTS " => 500},
          %{"max_results" => 1, " MAX_RESULTS " => 1}
        ] do
      reject(:grant, Map.put(attrs(:grant, "owned"), :constraints, constraints))
      assert_unchanged(context)
    end
  end

  defp attrs(:grant, owner) do
    %{
      id: "grant-" <> owner,
      principal_id: owner,
      issuer_principal_id: "issuer",
      actions: [:post_message],
      scope: AuthorizationScope.new(%{kind: :room, room_id: "owned-room"}),
      constraints: %{requires_membership: false},
      metadata: %{complete: owner}
    }
  end

  defp attrs(:credential, owner) do
    now = DateTime.utc_now()

    %{
      id: "credential-" <> owner,
      issuer_principal_id: "issuer",
      subject_principal_id: owner,
      provider_id: "fixture",
      proof_type: "opaque",
      proof_ref: "proof:" <> owner,
      conditions: %{audience: "fixture", room_ids: ["owned-room"]},
      issued_at: now,
      not_before: now,
      expires_at: DateTime.add(now, 3_600, :second),
      metadata: %{complete: owner}
    }
  end

  defp attrs(:endpoint, owner) do
    %{
      id: "endpoint-" <> owner,
      principal_id: owner,
      jidoka_agent_ref: %{system: :jidoka, id: "agent-" <> owner},
      metadata: %{complete: owner}
    }
  end

  defp create(:grant, attrs), do: Instance.create_principal_grant(attrs)
  defp create(:credential, attrs), do: Instance.create_identity_credential(attrs)
  defp create(:endpoint, attrs), do: Instance.create_agent_messaging_endpoint(attrs)
  defp get(:grant, id), do: Instance.get_principal_grant(id)
  defp get(:credential, id), do: Instance.get_identity_credential(id)
  defp get(:endpoint, id), do: Instance.get_agent_messaging_endpoint(id)
  defp reject(:credential, attrs), do: assert({:error, :invalid_identity_credential} == create(:credential, attrs))
  defp reject(kind, attrs), do: assert_raise(ArgumentError, fn -> create(kind, attrs) end)

  defp assert_unchanged(context) do
    assert Agent.get(Store.Control, & &1) == 0
    for {kind, original} <- context.records, do: assert({:ok, original} == get(kind, original.id))
    assert_no_communication(context)
  end

  defp assert_no_communication(context) do
    assert Jido.Messaging.TestHelpers.runtime_entry_count(context.runtime) == 0
    assert Instance.count_agents() == 0
    assert {:ok, []} = Instance.list_memberships(context.room.id)
    assert {:ok, []} = Instance.list_messages(context.room.id)
  end
end
