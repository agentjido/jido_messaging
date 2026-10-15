defmodule Jido.Messaging.Persistence.DirectoryRevisionScopeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Participant
  alias Jido.Messaging.{AgentDirectoryProjection, Persistence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} directory revision failures preserve immutable identity and owned records" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      original = projection("owned", "principal-owned", "endpoint-owned")
      foreign = projection("foreign", "principal-foreign", "endpoint-foreign")

      assert {:error, {:invalid_initial_revision, 2}} =
               adapter.save_agent_directory_projection(state, %{original | source_revision: 2})

      assert {:ok, ^original} = adapter.save_agent_directory_projection(state, original)
      assert {:ok, ^foreign} = adapter.save_agent_directory_projection(state, foreign)

      assert {:error, :agent_directory_identity_immutable} =
               adapter.save_agent_directory_projection(state, %{
                 original
                 | jidoka_agent_ref: %{"system" => "jidoka", "id" => "changed"},
                   source_revision: 2
               })

      assert {:error, :agent_directory_revision_conflict} =
               adapter.save_agent_directory_projection(state, %{original | name: "changed"})

      assert {:error, {:revision_gap, 1, 3}} =
               adapter.save_agent_directory_projection(state, %{original | source_revision: 3})

      assert {:ok, ^original} = adapter.get_agent_directory_projection(state, original.id)
      incoming = %{original | source_revision: 2, listing_state: :withdrawn, inserted_at: DateTime.utc_now()}
      assert {:ok, accepted} = adapter.save_agent_directory_projection(state, incoming)
      assert accepted.inserted_at == original.inserted_at
      assert {:ok, ^accepted} = adapter.save_agent_directory_projection(state, incoming)
      assert {:error, {:stale_revision, 2}} = adapter.save_agent_directory_projection(state, original)

      assert {:ok, [^accepted]} =
               adapter.list_agent_directory_projections(state, endpoint_ids: [original.endpoint_ref.id])

      assert {:ok, [^foreign]} =
               adapter.list_agent_directory_projections(state, endpoint_ids: [foreign.endpoint_ref.id])

      assert {:ok, []} = adapter.list_agent_directory_projections(state, endpoint_ids: [])

      assert {:error, :invalid_agent_directory_endpoint_filter} =
               adapter.list_agent_directory_projections(state, endpoint_ids: :invalid)

      assert {:ok, ^foreign} = adapter.get_agent_directory_projection(state, foreign.id)
    end

    test "#{adapter} participant deletion removes only its directory projections" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      for id <- ["owned", "foreign"] do
        participant = Participant.new(%{id: id, type: :agent})
        assert {:ok, ^participant} = adapter.save_participant(state, participant)
        assert {:ok, _} = adapter.save_agent_directory_projection(state, projection(id, id, "endpoint-" <> id))
      end

      assert :ok = adapter.delete_participant(state, "owned")
      assert {:ok, []} = adapter.list_agent_directory_projections(state, endpoint_ids: ["endpoint-owned"])
      assert {:ok, [foreign]} = adapter.list_agent_directory_projections(state, endpoint_ids: ["endpoint-foreign"])
      assert foreign.principal_id == "foreign"
    end
  end

  defp projection(id, principal, endpoint) do
    AgentDirectoryProjection.new(%{
      jidoka_agent_ref: %{system: :jidoka, id: id},
      principal_id: principal,
      endpoint_ref: %{system: :jido_messaging, id: endpoint},
      name: "Complete " <> id,
      description: "Safe display",
      capabilities: ["text"],
      availability: :available,
      version: "1",
      invocation_summary: %{mode: :thread, approval: :unknown},
      verification_state: :unverified,
      listing_state: :listed,
      source_revision: 1,
      source_updated_at: DateTime.utc_now(),
      fresh_for_seconds: 300
    })
  end
end
