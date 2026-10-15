defmodule Jido.Messaging.IngestStageOrderTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{Ingest, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name != :save_message do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_message(state, message) do
      probe = Process.get(:ingest_stage_probe)
      Agent.update(probe, &[{:write, message.id} | &1])
      result = ETS.save_message(state, message)
      if Process.get(:ingest_stage_write_failure), do: raise("after committed write"), else: result
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :stage_order
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _input), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)

    @impl true
    def open_thread(room, message, opts) do
      {:ok, committed} = Instance.get_message_by_external_id(:stage_order, "stages", message)
      Agent.update(opts[:probe], &[{:provider, committed.id} | &1])
      {:ok, %{external_thread_id: "thread", delivery_external_room_id: room}}
    end
  end

  defmodule Gater do
    @behaviour Jido.Messaging.Gating
    @impl true
    def check(_context, opts) do
      Agent.update(opts[:probe], &[:gating | &1])
      if opts[:deny], do: {:deny, :denied, "test denial"}, else: :allow
    end
  end

  defmodule Moderator do
    @behaviour Jido.Messaging.Moderation
    @impl true
    def moderate(_message, opts) do
      Agent.update(opts[:probe], &[:moderation | &1])
      if opts[:deny], do: {:reject, :denied, "test denial"}, else: :allow
    end
  end

  setup do
    start_supervised!(Instance)
    probe = start_supervised!({Agent, fn -> [] end})
    Process.put(:ingest_stage_probe, probe)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "stages", probe: probe)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, room} = Instance.get_or_create_room_by_external_binding(:stage_order, "stages", "room", %{type: :channel})
    {:ok, _} = Instance.register_agent(room.id, %{agent_id: "alpha", handler: fn _, _ -> :noreply end})

    handler = "ingest-stages-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:jido_messaging, :message, :received],
        fn _, _, metadata, probe ->
          if metadata.instance_module == Instance, do: Agent.update(probe, &[{:observed, metadata.message.id} | &1])
        end,
        probe
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{probe: probe, room: room}
  end

  for after_write_failure <- [false, true] do
    test "policies precede commit, then provider work and observations: after-write failure #{after_write_failure}",
         context do
      Process.put(:ingest_stage_write_failure, unquote(after_write_failure))

      assert {:ok, message, accepted_context} =
               Ingest.ingest_incoming(Instance, Adapter, "stages", incoming(), opts(context))

      id = message.id
      events = Agent.get(context.probe, &Enum.reverse/1)
      # Linking the new thread may update the same record after its initial commit.
      assert [:gating, :moderation, {:write, ^id}, {:provider, ^id}, {:write, ^id}, {:observed, ^id}] = events
      assert accepted_context.room.id == context.room.id
      assert {:ok, [stored]} = Instance.list_messages(context.room.id)
      assert stored.id == id
      assert {:ok, :duplicate} = Ingest.ingest_incoming(Instance, Adapter, "stages", incoming(), opts(context))
      assert Agent.get(context.probe, &Enum.reverse/1) == events
    end
  end

  for {stage, key, events} <- [
        {:gating, :gating_opts, [:gating]},
        {:moderation, :moderation_opts, [:gating, :moderation]}
      ] do
    test "#{stage} denial has no message write or provider call and permits retry", context do
      stage = unquote(stage)
      key = unquote(key)
      denied_opts = Keyword.update!(opts(context), key, &Keyword.put(&1, :deny, true))

      assert {:error, {:policy_denied, ^stage, :denied, "test denial"}} =
               Ingest.ingest_incoming(Instance, Adapter, "stages", incoming(), denied_opts)

      assert Agent.get(context.probe, &Enum.reverse/1) == unquote(events)

      assert {:ok, []} = Instance.list_messages(context.room.id)
      assert {:ok, message, _} = Ingest.ingest_incoming(Instance, Adapter, "stages", incoming(), opts(context))
      assert {:ok, [^message]} = Instance.list_messages(context.room.id)
      assert {:ok, :duplicate} = Ingest.ingest_incoming(Instance, Adapter, "stages", incoming(), opts(context))
    end
  end

  defp opts(context),
    do: [
      gaters: [Gater],
      gating_opts: [probe: context.probe],
      moderators: [Moderator],
      moderation_opts: [probe: context.probe]
    ]

  defp incoming do
    %{
      external_room_id: "room",
      external_user_id: "sender",
      external_message_id: "message",
      text: "@alpha hello",
      chat_type: :channel
    }
  end
end
