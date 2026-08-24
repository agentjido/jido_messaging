defmodule Jido.Messaging.Persistence.Conformance do
  @moduledoc """
  Reusable ExUnit contract for persistence adapters.

  Use this module in an adapter test. Give it a factory that starts a new
  adapter instance and a cleanup function that stops that instance.

      defmodule MyAdapterConformanceTest do
        use Jido.Messaging.Persistence.Conformance,
          adapter: MyAdapter,
          factory: {MyAdapterFactory, :start, []},
          cleanup: {MyAdapterFactory, :stop, []}
      end

  The factory must return `{:ok, state}`. The cleanup function receives the
  state as its first argument. Extra arguments in each MFA tuple follow the
  state argument.

  The suite starts a new adapter instance for each test. It also starts two
  instances for the isolation contract. A factory must therefore create a
  separate storage scope on each call.
  """

  @doc false
  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    factory = Keyword.fetch!(opts, :factory)
    cleanup = Keyword.fetch!(opts, :cleanup)
    async? = Keyword.get(opts, :async, false)
    tags = Keyword.get(opts, :tags, [])

    quote bind_quoted: [
            adapter: adapter,
            factory: factory,
            cleanup: cleanup,
            async?: async?,
            tags: tags
          ] do
      use ExUnit.Case, async: async?

      if tags != [], do: @moduletag(tags)

      alias Jido.Chat.{Participant, Room}

      alias Jido.Messaging.{
        BridgeConfig,
        IngressSubscription,
        Message,
        RoutingPolicy,
        Thread
      }

      @persistence_adapter adapter
      @persistence_factory factory
      @persistence_cleanup cleanup

      setup do
        {:ok, state} = Jido.Messaging.Persistence.Conformance.start(@persistence_factory)

        on_exit(fn ->
          Jido.Messaging.Persistence.Conformance.stop(@persistence_cleanup, state)
        end)

        {:ok, persistence: state}
      end

      test "returns not_found for records that do not exist", %{persistence: state} do
        assert {:error, :not_found} = @persistence_adapter.get_room(state, "missing-room")
        assert {:error, :not_found} = @persistence_adapter.get_participant(state, "missing-participant")
        assert {:error, :not_found} = @persistence_adapter.get_thread(state, "missing-thread")
        assert {:error, :not_found} = @persistence_adapter.get_message(state, "missing-message")
      end

      test "reports capabilities and storage health", %{persistence: state} do
        assert is_list(@persistence_adapter.capabilities(state))
        assert :ok = @persistence_adapter.health_check(state)
      end

      test "keeps adapter instances isolated", %{persistence: first} do
        {:ok, second} = Jido.Messaging.Persistence.Conformance.start(@persistence_factory)

        on_exit(fn ->
          Jido.Messaging.Persistence.Conformance.stop(@persistence_cleanup, second)
        end)

        room = Room.new(%{id: unique_id("room"), type: :direct})
        assert {:ok, ^room} = @persistence_adapter.save_room(first, room)
        assert {:error, :not_found} = @persistence_adapter.get_room(second, room.id)
      end

      test "round-trips and deletes core records", %{persistence: state} do
        room = Room.new(%{id: unique_id("room"), type: :group, name: "Contract room"})

        participant =
          Participant.new(%{
            id: unique_id("participant"),
            type: :human,
            identity: %{name: "Contract user"}
          })

        thread =
          Thread.new(%{
            id: unique_id("thread"),
            room_id: room.id,
            external_thread_id: unique_id("external-thread"),
            root_message_id: unique_id("root-message")
          })

        message = contract_message(room.id, unique_id("message"), participant.id)

        assert {:ok, ^room} = @persistence_adapter.save_room(state, room)
        assert {:ok, ^participant} = @persistence_adapter.save_participant(state, participant)
        assert {:ok, ^thread} = @persistence_adapter.save_thread(state, thread)
        assert {:ok, ^message} = @persistence_adapter.save_message(state, message)

        assert {:ok, ^room} = @persistence_adapter.get_room(state, room.id)
        assert {:ok, ^participant} = @persistence_adapter.get_participant(state, participant.id)
        assert {:ok, ^thread} = @persistence_adapter.get_thread(state, thread.id)
        assert {:ok, ^message} = @persistence_adapter.get_message(state, message.id)

        assert {:ok, ^thread} =
                 @persistence_adapter.get_thread_by_external_id(
                   state,
                   room.id,
                   thread.external_thread_id
                 )

        assert {:ok, ^thread} =
                 @persistence_adapter.get_thread_by_root_message(
                   state,
                   room.id,
                   thread.root_message_id
                 )

        assert :ok = @persistence_adapter.delete_message(state, message.id)
        assert :ok = @persistence_adapter.delete_participant(state, participant.id)
        assert {:error, :not_found} = @persistence_adapter.get_message(state, message.id)
        assert {:error, :not_found} = @persistence_adapter.get_participant(state, participant.id)
      end

      test "orders, filters, limits, and pages messages", %{persistence: state} do
        room = persist_room(state)
        thread = persist_thread(state, room.id)
        base = DateTime.from_unix!(1_700_000_000)

        messages =
          for offset <- 1..5 do
            message =
              contract_message(room.id, "message-#{offset}-#{unique_id("id")}", "sender",
                thread_id: if(offset <= 3, do: thread.id),
                inserted_at: DateTime.add(base, offset, :second)
              )

            assert {:ok, ^message} = @persistence_adapter.save_message(state, message)
            message
          end

        assert {:ok, listed} = @persistence_adapter.get_messages(state, room.id, limit: 3)
        assert Enum.map(listed, & &1.id) == messages |> Enum.drop(2) |> Enum.map(& &1.id)

        assert {:ok, threaded} =
                 @persistence_adapter.get_messages(state, room.id,
                   thread_id: thread.id,
                   limit: 10
                 )

        assert Enum.map(threaded, & &1.id) == messages |> Enum.take(3) |> Enum.map(& &1.id)

        assert {:ok, before} =
                 @persistence_adapter.get_messages(state, room.id,
                   before: Enum.at(messages, 3).id,
                   limit: 10
                 )

        assert Enum.map(before, & &1.id) == messages |> Enum.take(3) |> Enum.map(& &1.id)

        assert {:ok, after_page} =
                 @persistence_adapter.get_messages(state, room.id,
                   after: Enum.at(messages, 1).id,
                   limit: 10
                 )

        assert Enum.map(after_page, & &1.id) == messages |> Enum.drop(2) |> Enum.map(& &1.id)
      end

      test "room deletion clears child records and external indexes", %{persistence: state} do
        room = persist_room(state)
        thread = persist_thread(state, room.id)

        message =
          contract_message(room.id, unique_id("message"), "sender",
            thread_id: thread.id,
            external_id: unique_id("external-message"),
            metadata: %{channel: :slack, bridge_id: "contract-bridge"}
          )

        assert {:ok, ^message} = @persistence_adapter.save_message(state, message)

        assert {:ok, binding} =
                 @persistence_adapter.create_room_binding(
                   state,
                   room.id,
                   :slack,
                   "contract-bridge",
                   unique_id("external-room"),
                   %{}
                 )

        assert :ok = @persistence_adapter.delete_room(state, room.id)
        assert {:error, :not_found} = @persistence_adapter.get_room(state, room.id)
        assert {:error, :not_found} = @persistence_adapter.get_thread(state, thread.id)
        assert {:error, :not_found} = @persistence_adapter.get_message(state, message.id)

        assert {:error, :not_found} =
                 @persistence_adapter.get_message_by_external_id(
                   state,
                   :slack,
                   "contract-bridge",
                   message.external_id
                 )

        assert {:ok, []} = @persistence_adapter.list_room_bindings(state, room.id)
        assert {:error, :not_found} = @persistence_adapter.delete_room_binding(state, binding.id)
      end

      test "external message index follows an updated external id", %{persistence: state} do
        room = persist_room(state)
        old_id = unique_id("old-external-message")
        new_id = unique_id("new-external-message")

        message =
          contract_message(room.id, unique_id("message"), "sender",
            external_id: old_id,
            metadata: %{channel: :slack, bridge_id: "contract-bridge"}
          )

        assert {:ok, ^message} = @persistence_adapter.save_message(state, message)
        assert {:ok, updated} = @persistence_adapter.update_message_external_id(state, message.id, new_id)
        assert updated.external_id == new_id

        assert {:error, :not_found} =
                 @persistence_adapter.get_message_by_external_id(
                   state,
                   :slack,
                   "contract-bridge",
                   old_id
                 )

        assert {:ok, ^updated} =
                 @persistence_adapter.get_message_by_external_id(
                   state,
                   :slack,
                   "contract-bridge",
                   new_id
                 )
      end

      test "concurrent get-or-create returns one external room binding", %{persistence: state} do
        external_id = unique_id("external-room")

        results =
          1..12
          |> Task.async_stream(
            fn _index ->
              @persistence_adapter.get_or_create_room_by_external_binding(
                state,
                :slack,
                "contract-bridge",
                external_id,
                %{type: :channel, name: "Concurrent contract room"}
              )
            end,
            max_concurrency: 12,
            ordered: false,
            timeout: 10_000
          )
          |> Enum.map(fn {:ok, {:ok, room}} -> room end)

        assert results |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

        assert {:ok, room} =
                 @persistence_adapter.get_room_by_external_binding(
                   state,
                   :slack,
                   "contract-bridge",
                   external_id
                 )

        assert {:ok, [binding]} = @persistence_adapter.list_room_bindings(state, room.id)
        assert binding.external_room_id == external_id
      end

      test "concurrent participant binding claims return one participant", %{persistence: state} do
        external_id = unique_id("external-participant")

        participants =
          1..12
          |> Task.async_stream(
            fn _index ->
              @persistence_adapter.get_or_create_participant_by_external_binding(
                state,
                :slack,
                "contract-bridge",
                external_id,
                %{type: :human, identity: %{name: "Contract participant"}}
              )
            end,
            max_concurrency: 12,
            ordered: false,
            timeout: 10_000
          )
          |> Enum.map(fn {:ok, {:ok, participant}} -> participant end)

        assert participants |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

        assert {:ok, [stored]} =
                 @persistence_adapter.directory_search(
                   state,
                   :participant,
                   %{channel: :slack, external_id: external_id},
                   []
                 )

        assert stored.id == hd(participants).id
      end

      test "persists participant history and atomic read receipts", %{persistence: state} do
        room = persist_room(state)
        participant_id = unique_id("participant")

        messages =
          for offset <- 1..3 do
            message =
              contract_message(room.id, unique_id("history-message"), participant_id,
                inserted_at: DateTime.add(~U[2026-08-20 12:00:00Z], offset)
              )

            assert {:ok, ^message} = @persistence_adapter.save_message(state, message)
            message
          end

        assert {:ok, ^messages} =
                 @persistence_adapter.get_participant_messages(
                   state,
                   participant_id,
                   [room.id],
                   limit: 10
                 )

        receipt = %{
          bridge_id: "contract-bridge",
          external_message_id: "provider-message",
          read_at: ~U[2026-08-20 13:00:00Z]
        }

        message = List.last(messages)

        assert {:ok, updated, :updated} =
                 @persistence_adapter.mark_message_read(
                   state,
                   message.id,
                   participant_id,
                   receipt
                 )

        assert {:ok, ^updated, :unchanged} =
                 @persistence_adapter.mark_message_read(
                   state,
                   message.id,
                   participant_id,
                   receipt
                 )
      end

      test "round-trips directory and control-plane records", %{persistence: state} do
        room = persist_room(state)
        onboarding = %{onboarding_id: unique_id("onboarding"), step: :profile}

        bridge =
          BridgeConfig.new(%{
            id: unique_id("bridge"),
            adapter_module: Jido.Messaging.Adapters.Heartbeat
          })

        subscription =
          IngressSubscription.new(%{
            bridge_id: bridge.id,
            adapter_name: :heartbeat,
            subscription_id: unique_id("subscription"),
            status: :active
          })

        policy = RoutingPolicy.new(%{room_id: room.id, delivery_mode: :primary})

        assert {:ok, ^onboarding} = @persistence_adapter.save_onboarding(state, onboarding)
        assert {:ok, ^bridge} = @persistence_adapter.save_bridge_config(state, bridge)

        assert {:ok, ^subscription} =
                 @persistence_adapter.save_ingress_subscription(state, subscription)

        assert {:ok, ^policy} = @persistence_adapter.save_routing_policy(state, policy)

        assert {:ok, ^onboarding} =
                 @persistence_adapter.get_onboarding(state, onboarding.onboarding_id)

        assert {:ok, ^bridge} = @persistence_adapter.get_bridge_config(state, bridge.id)

        assert {:ok, [^subscription]} =
                 @persistence_adapter.list_ingress_subscriptions(state, bridge.id, status: :active)

        assert {:ok, ^policy} = @persistence_adapter.get_routing_policy(state, room.id)
        assert :ok = @persistence_adapter.delete_ingress_subscription(state, bridge.id, subscription.subscription_id)
        assert :ok = @persistence_adapter.delete_bridge_config(state, bridge.id)
        assert :ok = @persistence_adapter.delete_routing_policy(state, room.id)
      end

      defp persist_room(state) do
        room = Room.new(%{id: unique_id("room"), type: :direct})
        {:ok, ^room} = @persistence_adapter.save_room(state, room)
        room
      end

      defp persist_thread(state, room_id) do
        thread = Thread.new(%{id: unique_id("thread"), room_id: room_id})
        {:ok, ^thread} = @persistence_adapter.save_thread(state, thread)
        thread
      end

      defp contract_message(room_id, id, sender_id, opts \\ []) do
        Message.new(%{
          id: id,
          room_id: room_id,
          sender_id: sender_id,
          role: :user,
          content: [%{type: :text, text: id}],
          thread_id: Keyword.get(opts, :thread_id),
          external_id: Keyword.get(opts, :external_id),
          metadata: Keyword.get(opts, :metadata, %{}),
          inserted_at: Keyword.get(opts, :inserted_at, DateTime.utc_now())
        })
      end

      defp unique_id(prefix) do
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      end
    end
  end

  @doc false
  def start({module, function, arguments}) do
    apply(module, function, arguments)
  end

  @doc false
  def stop({module, function, arguments}, state) do
    apply(module, function, [state | arguments])
  end
end
