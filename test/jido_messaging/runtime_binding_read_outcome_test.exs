defmodule Jido.Messaging.RuntimeBindingReadOutcomeTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{BridgeConfig, ConfigStore, Persistence.ETS, Runtime, SecretResolver}

  defmodule Store do
    def init(opts), do: ETS.init(opts)
    defdelegate list_bridge_configs(state, opts), to: ETS
    defdelegate list_room_bindings(state, room), to: ETS

    def get_bridge_config(state, id) do
      case Agent.get(__MODULE__.Control, & &1) do
        :pass ->
          ETS.get_bridge_config(state, id)

        :error ->
          {:error, :bridge_read_unavailable}

        :raise ->
          raise "private bridge read"

        :throw ->
          throw(:private_bridge_read)

        :exit ->
          exit(:private_bridge_read)

        :invalid ->
          :invalid

        :invalid_record ->
          {:ok, %{adapter_module: Adapter}}

        :foreign_record ->
          {:ok, record} = ETS.get_bridge_config(state, id)
          {:ok, %{record | id: "foreign"}}
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :runtime_read_outcome
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts) do
      send(opts[:notify], :configured)
      {:ok, opts}
    end

    @impl true
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
  end

  setup do
    start_supervised!(%{id: Store.Control, start: {Agent, :start_link, [fn -> :pass end, [name: Store.Control]]}})
    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)
    config = BridgeConfig.new(%{id: "owned", adapter_module: Adapter, revision: 1})
    {:ok, ^config} = ETS.save_bridge_config(state, config)
    {:ok, runtime: runtime, state: state, config: config}
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record, :foreign_record] do
    test "new binding #{mode} read fails before configure and preserves the runtime", context do
      Agent.update(Store.Control, fn _ -> unquote(mode) end)
      expected = expected(unquote(mode))
      assert {:error, ^expected} = Runtime.ensure_binding(context.runtime, Adapter, "owned", notify: self())
      assert Process.alive?(Process.whereis(context.runtime))
      refute_received :configured
      assert Runtime.get_state(context.runtime).bindings == %{}
      assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
      assert {:ok, stored} = ETS.get_bridge_config(context.state, "owned")
      assert stored == context.config
    end

    test "current binding #{mode} read retains the binding and returns a failure", context do
      assert {:ok, binding} = Runtime.ensure_binding(context.runtime, Adapter, "owned", notify: self())
      assert_received :configured
      Agent.update(Store.Control, fn _ -> unquote(mode) end)
      expected = expected(unquote(mode))
      assert {:error, ^expected} = Runtime.binding(context.runtime, "owned")
      assert Process.alive?(Process.whereis(context.runtime))
      assert Runtime.get_state(context.runtime).bindings == %{"owned" => binding}
      assert :ets.info(binding.resources, :size) == 0
      refute_received :configured
      Agent.update(Store.Control, fn _ -> :pass end)
      assert {:ok, ^binding} = Runtime.binding(context.runtime, "owned")
    end

    test "secret adapter options #{mode} read returns failure without a configure callback", context do
      Agent.update(Store.Control, fn _ -> unquote(mode) end)
      expected = expected(unquote(mode))
      assert {:error, ^expected} = SecretResolver.adapter_opts(Instance, "owned", Adapter, :configure, notify: self())
      assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))
      assert Runtime.get_state(context.runtime).bindings == %{}
      refute_received :configured
    end
  end

  defp expected(:error), do: :bridge_read_unavailable
  defp expected(_), do: :persistence_failed
end
