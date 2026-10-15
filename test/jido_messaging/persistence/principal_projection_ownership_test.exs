defmodule Jido.Messaging.Persistence.PrincipalProjectionOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Participant
  alias Jido.Messaging.Persistence
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ] do
    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} projection and controller errors preserve principal ownership" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      agent = Participant.new(%{id: "owned-agent", type: :agent})
      controller = Participant.new(%{id: "owned-controller", type: :human})
      for person <- [agent, controller], do: assert({:ok, person} == adapter.save_participant(state, person))
      assert {:ok, principal} = adapter.get_principal(state, agent.id)
      assert {:ok, controller_principal} = adapter.get_principal(state, controller.id)

      for invalid <- [%{principal | id: "different-id"}, %{principal | type: :human}] do
        assert {:error, :principal_participant_mismatch} = adapter.save_principal(state, invalid)
        assert {:ok, ^principal} = adapter.get_principal(state, agent.id)
      end

      assert {:error, :principal_participant_mismatch} = adapter.save_participant(state, %{agent | type: :human})
      assert {:ok, ^agent} = adapter.get_participant(state, agent.id)

      assert {:error, :controller_principal_not_found} =
               adapter.save_principal(state, %{principal | controller_principal_id: "missing"})

      assert {:error, :principal_cannot_control_itself} =
               adapter.save_principal(state, %{principal | controller_principal_id: agent.id})

      for status <- [:suspended, :revoked] do
        inactive = %{controller_principal | status: status}
        assert {:ok, ^inactive} = adapter.save_principal(state, inactive)

        assert {:error, {:controller_principal_inactive, ^status}} =
                 adapter.save_principal(state, %{principal | controller_principal_id: controller.id})

        assert {:ok, ^principal} = adapter.get_principal(state, agent.id)
      end

      revoked_verification = %{controller_principal | verification_state: :revoked}
      assert {:ok, ^revoked_verification} = adapter.save_principal(state, revoked_verification)

      assert {:error, :controller_principal_verification_revoked} =
               adapter.save_principal(state, %{principal | controller_principal_id: controller.id})

      assert {:ok, ^controller_principal} = adapter.save_principal(state, controller_principal)
      controlled = %{principal | controller_principal_id: controller.id}
      assert {:ok, ^controlled} = adapter.save_principal(state, controlled)
      assert {:ok, ^agent} = adapter.save_participant(state, agent)
      assert {:ok, ^controlled} = adapter.get_principal(state, agent.id)
      assert {:ok, ^agent} = adapter.get_participant(state, agent.id)
      assert {:ok, ^controller} = adapter.get_participant(state, controller.id)
    end
  end
end
