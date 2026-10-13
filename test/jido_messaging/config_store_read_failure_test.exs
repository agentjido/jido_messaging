defmodule Jido.Messaging.ConfigStoreReadFailureTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{ConfigStore, Persistence.ETS}

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :config_read_failure
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  defmodule ControlledStore do
    def init(opts), do: ETS.init(opts)
    defdelegate list_bridge_configs(state, opts), to: ETS
    defdelegate list_room_bindings(state, room), to: ETS
    def get_bridge_config(state, id), do: read(fn -> ETS.get_bridge_config(state, id) end)
    def get_routing_policy(state, id), do: read(fn -> ETS.get_routing_policy(state, id) end)
    def save_bridge_config(state, config), do: write(fn -> ETS.save_bridge_config(state, config) end)
    def save_routing_policy(state, policy), do: write(fn -> ETS.save_routing_policy(state, policy) end)

    defp read(fun) do
      case Agent.get(__MODULE__.Control, & &1.mode) do
        :pass ->
          fun.()

        :error ->
          {:error, :read_unavailable}

        :raise ->
          raise "private read failure"

        :throw ->
          throw(:private_read_failure)

        :exit ->
          exit(:private_read_failure)

        :invalid ->
          :invalid

        :invalid_record ->
          {:ok, %{revision: 1}}

        :foreign_record ->
          case fun.() do
            {:ok, record} -> {:ok, %{record | id: "foreign-id"}}
            result -> result
          end
      end
    end

    defp write(fun) do
      Agent.update(__MODULE__.Control, &Map.update!(&1, :attempts, fn n -> n + 1 end))

      case Agent.get(__MODULE__.Control, & &1.write_mode) do
        :pass ->
          Agent.update(__MODULE__.Control, &Map.update!(&1, :writes, fn n -> n + 1 end))
          fun.()

        {:after_write, failure} ->
          Agent.update(__MODULE__.Control, &Map.update!(&1, :writes, fn n -> n + 1 end))
          {:ok, _} = fun.()
          fail_after_write(failure)

        :error ->
          {:error, :write_unavailable}

        :raise ->
          raise "private write failure"

        :throw ->
          throw(:private_write_failure)

        :exit ->
          exit(:private_write_failure)

        :invalid ->
          :invalid
      end
    end

    defp fail_after_write(:error), do: {:error, :write_unavailable}
    defp fail_after_write(:raise), do: raise("private after-write failure")
    defp fail_after_write(:throw), do: throw(:private_after_write_failure)
    defp fail_after_write(:exit), do: exit(:private_after_write_failure)
    defp fail_after_write(:invalid), do: :invalid
  end

  defmodule Runtime do
    use Jido.Messaging, persistence: ControlledStore
  end

  setup do
    start_supervised!(%{
      id: ControlledStore.Control,
      start:
        {Agent, :start_link,
         [fn -> %{mode: :pass, write_mode: :pass, writes: 0, attempts: 0} end, [name: ControlledStore.Control]]}
    })

    start_supervised!(Runtime)
    :ok
  end

  for kind <- [:bridge, :routing], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{kind} #{failure} write failure retains old revision and permits one retry" do
      kind = unquote(kind)
      pid = Process.whereis(ConfigStore.name(Runtime))
      assert {:ok, initial} = put_config(kind, pid, initial_attrs(kind))
      before = Agent.get(ControlledStore.Control, & &1)
      Agent.update(ControlledStore.Control, &%{&1 | write_mode: unquote(failure)})
      expected = expected_write_failure(unquote(failure))
      assert {:error, ^expected} = put_config(kind, pid, update_attrs(kind, initial.revision))
      assert Process.alive?(pid)
      assert {:ok, ^initial} = get_config(kind, pid)
      current = Agent.get(ControlledStore.Control, & &1)
      assert current.attempts == before.attempts + 1
      assert current.writes == before.writes
      Agent.update(ControlledStore.Control, &%{&1 | write_mode: :pass})
      assert {:ok, next} = put_config(kind, pid, update_attrs(kind, initial.revision))
      assert next.revision == initial.revision + 1
      assert Agent.get(ControlledStore.Control, & &1.writes) == before.writes + 1
    end
  end

  defp expected_write_failure(:error), do: :write_unavailable
  defp expected_write_failure(_failure), do: :persistence_failed

  for kind <- [:bridge, :routing], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{kind} #{failure} after-write failure keeps one revision and rejects stale retry" do
      kind = unquote(kind)
      pid = Process.whereis(ConfigStore.name(Runtime))
      assert {:ok, initial} = put_config(kind, pid, initial_attrs(kind))
      before = Agent.get(ControlledStore.Control, & &1)
      Agent.update(ControlledStore.Control, &%{&1 | write_mode: {:after_write, unquote(failure)}})
      expected = expected_write_failure(unquote(failure))
      assert {:error, ^expected} = put_config(kind, pid, update_attrs(kind, initial.revision))
      assert Process.alive?(pid)
      assert {:ok, saved} = get_config(kind, pid)
      assert saved.revision == initial.revision + 1
      assert Agent.get(ControlledStore.Control, & &1.writes) == before.writes + 1
      Agent.update(ControlledStore.Control, &%{&1 | write_mode: :pass})

      assert {:error, {:revision_conflict, expected_revision, actual_revision}} =
               put_config(kind, pid, update_attrs(kind, initial.revision))

      assert expected_revision == initial.revision
      assert actual_revision == saved.revision
      assert Agent.get(ControlledStore.Control, & &1.attempts) == before.attempts + 1
      assert {:ok, ^saved} = get_config(kind, pid)
    end
  end

  for kind <- [:bridge, :routing],
      failure <- [:error, :raise, :throw, :exit, :invalid, :invalid_record, :foreign_record] do
    test "#{kind} #{failure} read failure has no write and preserves the config process" do
      kind = unquote(kind)
      pid = Process.whereis(ConfigStore.name(Runtime))
      assert {:ok, initial} = put_config(kind, pid, initial_attrs(kind))
      before = Agent.get(ControlledStore.Control, & &1.writes)
      Agent.update(ControlledStore.Control, &%{&1 | mode: unquote(failure)})
      expected = expected_failure(unquote(failure))
      assert {:error, ^expected} = put_config(kind, pid, update_attrs(kind, initial.revision))
      assert Process.alive?(pid)
      assert Agent.get(ControlledStore.Control, & &1.writes) == before

      Agent.update(ControlledStore.Control, &%{&1 | mode: :pass})
      assert {:ok, ^initial} = get_config(kind, pid)
      assert {:ok, next} = put_config(kind, pid, update_attrs(kind, initial.revision))
      assert next.revision == initial.revision + 1
      assert Agent.get(ControlledStore.Control, & &1.writes) == before + 1
      assert {:ok, ^next} = get_config(kind, pid)
    end
  end

  defp expected_failure(:error), do: :read_unavailable
  defp expected_failure(_failure), do: :persistence_failed

  defp initial_attrs(:bridge), do: %{id: "owned-bridge", adapter_module: Adapter, enabled: false}
  defp initial_attrs(:routing), do: %{delivery_mode: :primary}

  defp update_attrs(:bridge, revision),
    do: %{id: "owned-bridge", revision: revision, enabled: false, opts: %{revision: true}}

  defp update_attrs(:routing, revision), do: %{revision: revision, delivery_mode: :broadcast}
  defp put_config(:bridge, pid, attrs), do: ConfigStore.put_bridge_config(pid, attrs)
  defp put_config(:routing, pid, attrs), do: ConfigStore.put_routing_policy(pid, "owned-room", attrs)
  defp get_config(:bridge, pid), do: ConfigStore.get_bridge_config(pid, "owned-bridge")
  defp get_config(:routing, pid), do: ConfigStore.get_routing_policy(pid, "owned-room")
end
