defmodule JidoMessaging.OnboardingTest do
  use ExUnit.Case, async: false

  import JidoMessaging.TestHelpers

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "onboarding state orchestration" do
    test "happy path transitions deterministically and persists completion metadata" do
      onboarding_id = onboarding_id("happy")

      assert {:ok, started_flow} =
               TestMessaging.start_onboarding(%{
                 onboarding_id: onboarding_id,
                 requester: "user_1",
                 channel: :slack
               })

      assert started_flow.status == :started

      assert {:ok, %{flow: after_directory, transition: directory_transition}} =
               TestMessaging.advance_onboarding(
                 onboarding_id,
                 :resolve_directory,
                 %{match_type: :participant, match_id: "participant_1"},
                 idempotency_key: "dir-1"
               )

      assert directory_transition.status == :directory_resolved
      assert directory_transition.idempotent == false
      assert after_directory.status == :directory_resolved

      assert {:ok, %{flow: after_pairing, transition: pairing_transition}} =
               TestMessaging.advance_onboarding(
                 onboarding_id,
                 :pair_identity,
                 %{participant_id: "participant_1", room_id: "room_1"},
                 idempotency_key: "pair-1"
               )

      assert pairing_transition.status == :paired
      assert after_pairing.status == :paired

      completion_metadata = %{bootstrap: :ok, paired_at: "2026-02-14T00:00:00Z"}

      assert {:ok, %{flow: completed_flow, transition: completed_transition}} =
               TestMessaging.complete_onboarding(
                 onboarding_id,
                 completion_metadata,
                 idempotency_key: "complete-1"
               )

      assert completed_transition.status == :completed
      assert completed_flow.status == :completed
      assert completed_flow.completion_metadata == completion_metadata

      assert {:ok, persisted_flow} = TestMessaging.get_onboarding(onboarding_id)
      assert persisted_flow.status == :completed
      assert persisted_flow.completion_metadata == completion_metadata
      assert Enum.map(persisted_flow.transitions, & &1.transition) == [:resolve_directory, :pair_identity, :complete]
    end

    test "invalid transitions are rejected and idempotency prevents duplicate effects" do
      onboarding_id = onboarding_id("guards")
      {:ok, _flow} = TestMessaging.start_onboarding(%{onboarding_id: onboarding_id})

      assert {:error,
              {:invalid_transition,
               %{from: :started, transition: :pair_identity, allowed: [:cancel, :resolve_directory], class: :fatal}}} =
               TestMessaging.advance_onboarding(
                 onboarding_id,
                 :pair_identity,
                 %{participant_id: "participant_1"},
                 idempotency_key: "pair-invalid"
               )

      assert {:ok, %{flow: resolved_flow, transition: first_transition}} =
               TestMessaging.advance_onboarding(
                 onboarding_id,
                 :resolve_directory,
                 %{match_id: "participant_1"},
                 idempotency_key: "dir-idempotent"
               )

      assert first_transition.idempotent == false
      assert length(resolved_flow.transitions) == 1
      assert length(resolved_flow.side_effects) == 1

      assert {:ok, %{flow: resolved_flow_again, transition: duplicate_transition}} =
               TestMessaging.advance_onboarding(
                 onboarding_id,
                 :resolve_directory,
                 %{match_id: "participant_1"},
                 idempotency_key: "dir-idempotent"
               )

      assert duplicate_transition.idempotent == true
      assert resolved_flow_again.status == :directory_resolved
      assert length(resolved_flow_again.transitions) == 1
      assert length(resolved_flow_again.side_effects) == 1

      assert {:error,
              {:invalid_transition,
               %{
                 from: :directory_resolved,
                 transition: :resolve_directory,
                 allowed: [:cancel, :pair_identity],
                 class: :fatal
               }}} =
               TestMessaging.advance_onboarding(
                 onboarding_id,
                 :resolve_directory,
                 %{match_id: "participant_1"},
                 idempotency_key: "dir-new-key"
               )
    end

    test "resume restores persisted state after interruption without duplicate side effects" do
      onboarding_id = onboarding_id("resume")
      {:ok, _flow} = TestMessaging.start_onboarding(%{onboarding_id: onboarding_id})

      {:ok, %{flow: _flow}} =
        TestMessaging.advance_onboarding(
          onboarding_id,
          :resolve_directory,
          %{match_id: "participant_1"},
          idempotency_key: "dir-resume"
        )

      {:ok, %{flow: _flow}} =
        TestMessaging.advance_onboarding(
          onboarding_id,
          :pair_identity,
          %{participant_id: "participant_1", room_id: "room_1"},
          idempotency_key: "pair-resume"
        )

      worker_pid = TestMessaging.whereis_onboarding_worker(onboarding_id)
      assert is_pid(worker_pid)

      ref = Process.monitor(worker_pid)
      Process.exit(worker_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 1_000

      assert {:ok, resumed_flow} = TestMessaging.resume_onboarding(onboarding_id)
      assert resumed_flow.status == :paired

      assert {:ok, %{flow: completed_flow, transition: completion_transition}} =
               TestMessaging.complete_onboarding(
                 onboarding_id,
                 %{bootstrap: :ok},
                 idempotency_key: "complete-resume"
               )

      assert completion_transition.idempotent == false
      assert completed_flow.status == :completed

      reloaded_worker = TestMessaging.whereis_onboarding_worker(onboarding_id)
      ref = Process.monitor(reloaded_worker)
      Process.exit(reloaded_worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^reloaded_worker, _reason}, 1_000

      assert {:ok, _resumed_completed_flow} = TestMessaging.resume_onboarding(onboarding_id)

      assert {:ok, %{flow: completed_flow_again, transition: duplicate_completion}} =
               TestMessaging.complete_onboarding(
                 onboarding_id,
                 %{bootstrap: :ok},
                 idempotency_key: "complete-resume"
               )

      assert duplicate_completion.idempotent == true
      assert completed_flow_again.status == :completed
      assert length(completed_flow_again.transitions) == 3
      assert length(completed_flow_again.side_effects) == 3
    end

    test "worker crashes are isolated and other onboarding flows continue" do
      onboarding_a = onboarding_id("isolation_a")
      onboarding_b = onboarding_id("isolation_b")

      {:ok, _} = TestMessaging.start_onboarding(%{onboarding_id: onboarding_a})
      {:ok, _} = TestMessaging.start_onboarding(%{onboarding_id: onboarding_b})

      pid_a = TestMessaging.whereis_onboarding_worker(onboarding_a)
      pid_b = TestMessaging.whereis_onboarding_worker(onboarding_b)

      assert is_pid(pid_a)
      assert is_pid(pid_b)
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)

      ref = Process.monitor(pid_a)
      Process.exit(pid_a, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_a, _reason}, 1_000

      assert Process.alive?(pid_b)

      assert_eventually(
        fn ->
          case TestMessaging.whereis_onboarding_worker(onboarding_a) do
            nil ->
              false

            restarted_pid ->
              is_pid(restarted_pid) and restarted_pid != pid_a and Process.alive?(restarted_pid)
          end
        end,
        timeout: 1_000
      )

      assert {:ok, %{flow: flow_b, transition: transition_b}} =
               TestMessaging.advance_onboarding(
                 onboarding_b,
                 :resolve_directory,
                 %{match_id: "participant_b"},
                 idempotency_key: "dir-b"
               )

      assert transition_b.status == :directory_resolved
      assert flow_b.status == :directory_resolved
    end
  end

  defp onboarding_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
