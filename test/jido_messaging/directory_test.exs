defmodule JidoMessaging.DirectoryTest do
  use ExUnit.Case, async: true

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "directory API" do
    test "lookup reports ambiguity and search returns deterministic results" do
      {:ok, participant_a} =
        TestMessaging.create_participant(%{
          type: :human,
          identity: %{name: "Casey Jordan"},
          external_ids: %{slack: "casey_a"}
        })

      {:ok, participant_b} =
        TestMessaging.create_participant(%{
          type: :human,
          identity: %{name: "Casey Lee"},
          external_ids: %{slack: "casey_b"}
        })

      assert {:ok, matches} = TestMessaging.directory_search(:participant, %{name: "casey"})
      assert Enum.map(matches, & &1.id) == Enum.sort([participant_a.id, participant_b.id])

      assert {:error, {:ambiguous, ambiguous_matches}} =
               TestMessaging.directory_lookup(:participant, %{name: "casey"})

      assert Enum.map(ambiguous_matches, & &1.id) == Enum.map(matches, & &1.id)

      assert {:ok, found} =
               TestMessaging.directory_lookup(:participant, %{channel: :slack, external_id: "casey_b"})

      assert found.id == participant_b.id
    end

    test "room lookup resolves by external binding" do
      {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Ops"})

      {:ok, _binding} =
        TestMessaging.create_room_binding(room.id, :telegram, "bot_1", "room_9", %{direction: :both})

      assert {:ok, resolved_room} =
               TestMessaging.directory_lookup(
                 :room,
                 %{channel: :telegram, instance_id: "bot_1", external_id: "room_9"}
               )

      assert resolved_room.id == room.id
    end
  end
end
