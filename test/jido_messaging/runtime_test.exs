defmodule Jido.Messaging.RuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Runtime
  alias Jido.Messaging.Adapters.ETS

  describe "Runtime" do
    test "get_state/1 returns full runtime state" do
      {:ok, pid} =
        Runtime.start_link(
          name: :test_runtime_state,
          instance_module: TestModule,
          adapter: ETS,
          adapter_opts: []
        )

      state = Runtime.get_state(pid)

      assert %Runtime{} = state
      assert state.instance_module == TestModule
      assert state.adapter == ETS
      assert is_struct(state.adapter_state, ETS)
    end

    test "get_adapter/1 returns adapter and state" do
      {:ok, pid} =
        Runtime.start_link(
          name: :test_runtime_adapter,
          instance_module: TestModule2,
          adapter: ETS,
          adapter_opts: []
        )

      {adapter, adapter_state} = Runtime.get_adapter(pid)

      assert adapter == ETS
      assert is_struct(adapter_state, ETS)
    end
  end
end
