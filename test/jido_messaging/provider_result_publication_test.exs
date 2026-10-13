defmodule Jido.Messaging.ProviderResultPublicationTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{AuthorizationScope, Runtime}
  alias Jido.Messaging.Signal.FetchChannelMessages

  defmodule Adapter do
    use Jido.Chat.Adapter
    def channel_type, do: :result_publication
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])

    def fetch_channel_messages(room, opts) do
      Agent.update(__MODULE__.Control, &(&1 ++ [{room, opts[:cursor]}]))
      {:ok, opts[:page]}
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(%{id: Adapter.Control, start: {Agent, :start_link, [fn -> [] end, [name: Adapter.Control]]}})
    start_supervised!(Instance)

    page = %{
      "messages" => [
        %{"id" => "provider-message", "room_id" => "provider-room", "text" => String.duplicate("x", 300_000)}
      ],
      "next_cursor" => "next-page",
      "complete" => false
    }

    {:ok, binding} = Jido.Chat.bind(Adapter, id: "provider-result", page: page)
    runtime = Instance.__jido_messaging__(:runtime)
    :ok = Runtime.register_binding(runtime, binding)

    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:result_publication, binding.id, "provider-room", %{type: :group})

    {:ok, foreign_room} = Instance.create_room(%{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    messages =
      for owned_room <- [room, foreign_room] do
        {:ok, message} =
          Instance.save_message(%{
            room_id: owned_room.id,
            sender_id: participant.id,
            role: :user,
            content: [%{type: :text, text: "Complete canonical content"}],
            metadata: %{complete: owned_room.id}
          })

        message
      end

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: binding.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:fetch_channel_messages],
        scope: scope,
        constraints: %{requires_membership: false}
      })

    {:ok, old_result} = Jido.Chat.put_resource(binding, "result", %{"complete" => "unrelated"})

    {:ok, input_file} =
      Jido.Chat.put_resource(binding, "file", Jido.Chat.FileUpload.new(%{data: "private fixture bytes"}))

    old_rows = :ets.tab2list(binding.resources) |> Enum.sort()

    request =
      FetchChannelMessages.new!(%{
        "request_id" => "one-query",
        "room_id" => room.id,
        "bridge_id" => binding.id,
        "cursor" => "previous-page"
      })

    {:ok,
     binding: binding,
     runtime: runtime,
     room: room,
     participant: participant,
     messages: messages,
     page: page,
     old_result: old_result,
     input_file: input_file,
     old_rows: old_rows,
     request: request,
     actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  test "failed result publication cancels only its prepared result and cannot repeat the query", context do
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Module.concat(Instance, SignalBus))
    {id, ^bus, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == bus end)
    :ok = Supervisor.terminate_child(supervisor, id)
    before = Jido.Signal.to_map(context.request)
    assert {:ok, failed} = Instance.execute(context.request, context.actor)
    assert failed.type == "jido.messaging.operation.failed"
    assert failed.data["code"] == "observation_failed"
    assert Jido.Signal.Context.get(failed, "causationid") == context.request.id
    assert Jido.Signal.to_map(context.request) == before

    new_rows =
      (:ets.tab2list(context.binding.resources) -- context.old_rows)
      |> Enum.filter(&match?({{:resource, _}, _, _, _, _, _}, &1))

    states = Enum.map(new_rows, fn {{:resource, _}, _, kind, value, _, status} -> {kind, is_nil(value), status} end)
    assert states == [{"result", true, :cancelled}]
    all_rows = :ets.tab2list(context.binding.resources) |> Enum.sort()
    assert {:ok, ^failed} = Instance.execute(context.request, context.actor)
    assert :ets.tab2list(context.binding.resources) |> Enum.sort() == all_rows
    assert Agent.get(Adapter.Control, & &1) == [{"provider-room", "previous-page"}]
    assert_existing(context)
  end

  test "published result retains the whole page, cursor, ownership and exactly one callback", context do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.operation.completed")
    before = Jido.Signal.to_map(context.request)
    assert {:ok, completed} = Instance.execute(context.request, context.actor)
    assert completed.type == "jido.messaging.operation.completed"
    ref = completed.data["result"]["resource_ref"]
    assert {:ok, page} = Instance.resolve_resource(ref)
    assert page == context.page
    assert_receive {:signal, ^completed}
    assert {:ok, ^completed} = Instance.execute(context.request, context.actor)
    assert Agent.get(Adapter.Control, & &1) == [{"provider-room", "previous-page"}]
    assert Jido.Signal.to_map(context.request) == before
    assert Jido.Signal.Context.get(completed, "causationid") == context.request.id
    task = Task.async(fn -> Instance.resolve_resource(ref) end)
    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_owner_mismatch}} = Task.await(task)
    assert {:ok, ^page} = Instance.resolve_resource(ref)
    assert_existing(context)
    refute_receive {:signal, _}
  end

  defp assert_existing(context) do
    for row <- context.old_rows, do: assert(row in :ets.tab2list(context.binding.resources))
    assert {:ok, %{"complete" => "unrelated"}} = Instance.resolve_resource(context.old_result)
    assert {:ok, %Jido.Chat.FileUpload{}} = Instance.resolve_resource(context.input_file)
    for original <- context.messages, do: assert({:ok, original} == Instance.get_message(original.id))
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 1
    assert Instance.count_agents() == 0
    assert {:ok, []} = Instance.list_memberships(context.room.id)
  end
end
