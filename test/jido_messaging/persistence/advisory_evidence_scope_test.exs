defmodule Jido.Messaging.Persistence.AdvisoryEvidenceScopeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{Persistence, TrustEvidence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} advisory query preserves exact principal and room scope across immutable revisions" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      older = evidence("subject", "room", "one", 1, 1)
      newer = evidence("subject", "room", "two", 1, 2)
      foreign_room = evidence("subject", "foreign", "foreign-room", 1, 3)
      foreign_subject = evidence("other", "room", "foreign-subject", 1, 4)

      for entry <- [older, newer, foreign_room, foreign_subject],
          do: assert({:ok, entry} == adapter.save_trust_evidence(state, entry))

      assert {:ok, ^older} = adapter.save_trust_evidence(state, older)

      assert {:error, :trust_evidence_revision_conflict} =
               adapter.save_trust_evidence(state, %{older | outcome: :failed})

      assert {:ok, [^newer, ^older]} = adapter.list_trust_evidence(state, "subject", "room")
      assert {:ok, [^newer]} = adapter.list_trust_evidence(state, "subject", "room", limit: 1)

      for limit <- [0, -1, "1"],
          do: assert({:error, :invalid_limit} == adapter.list_trust_evidence(state, "subject", "room", limit: limit))

      assert {:ok, [^foreign_room]} = adapter.list_trust_evidence(state, "subject", "foreign")
      assert {:ok, [^foreign_subject]} = adapter.list_trust_evidence(state, "other", "room")
      revision = evidence("subject", "room", "one", 2, 5)
      assert {:ok, ^revision} = adapter.save_trust_evidence(state, revision)
      assert revision.claim_id == older.claim_id
      assert revision.id != older.id
      assert {:ok, [^revision, ^newer, ^older]} = adapter.list_trust_evidence(state, "subject", "room")
    end

    test "#{adapter} room and issuer cleanup preserve unrelated advisory evidence" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      owned_room = Room.new(%{id: "owned", type: :group})
      foreign_room = Room.new(%{id: "foreign", type: :group})
      for room <- [owned_room, foreign_room], do: assert({:ok, room} == adapter.save_room(state, room))
      issuer = Participant.new(%{id: "issuer", type: :human})
      assert {:ok, ^issuer} = adapter.save_participant(state, issuer)
      owned = evidence("subject", owned_room.id, "owned", 1, 1)
      foreign = %{evidence("other", foreign_room.id, "foreign", 1, 2) | issuer_principal_id: "other-issuer"}
      issuer_owned = evidence("subject", foreign_room.id, "issuer", 1, 3)
      for entry <- [owned, foreign, issuer_owned], do: assert({:ok, entry} == adapter.save_trust_evidence(state, entry))
      assert :ok = adapter.delete_room(state, owned_room.id)
      assert {:ok, []} = adapter.list_trust_evidence(state, "subject", owned_room.id)
      assert {:ok, [^issuer_owned]} = adapter.list_trust_evidence(state, "subject", foreign_room.id)
      assert :ok = adapter.delete_participant(state, issuer.id)
      assert {:ok, []} = adapter.list_trust_evidence(state, "subject", foreign_room.id)
      assert {:ok, [^foreign]} = adapter.list_trust_evidence(state, "other", foreign_room.id)
      assert {:ok, ^foreign_room} = adapter.get_room(state, foreign_room.id)
    end
  end

  defp evidence(subject, room, source_id, revision, second) do
    observed = DateTime.add(~U[2026-10-13 05:00:00Z], second, :second)

    TrustEvidence.new(%{
      room_id: room,
      subject_principal_id: subject,
      subject_jidoka_agent_ref: %{system: :jidoka, id: "agent-" <> subject},
      issuer_principal_id: "issuer",
      capability_scope: ["text"],
      outcome: :succeeded,
      source: %{kind: :provider_record, provider_id: "fixture", id: source_id, revision: revision},
      verification_state: :unverified,
      observed_at: observed,
      expires_at: DateTime.add(observed, 86_400, :second)
    })
  end
end
