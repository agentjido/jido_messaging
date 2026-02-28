defmodule Jido.Messaging.RuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Runtime
  alias Jido.Messaging.Persistence.ETS

  describe "Runtime" do
    test "get_state/1 returns full runtime state" do
      {:ok, pid} =
        Runtime.start_link(
          name: :test_runtime_state,
          instance_module: TestModule,
          persistence: ETS,
          persistence_opts: []
        )

      state = Runtime.get_state(pid)

      assert %Runtime{} = state
      assert state.instance_module == TestModule
      assert state.persistence == ETS
      assert is_struct(state.persistence_state, ETS)
    end

    test "get_persistence/1 returns persistence and state" do
      {:ok, pid} =
        Runtime.start_link(
          name: :test_runtime_adapter,
          instance_module: TestModule2,
          persistence: ETS,
          persistence_opts: []
        )

      {persistence, persistence_state} = Runtime.get_persistence(pid)

      assert persistence == ETS
      assert is_struct(persistence_state, ETS)
    end
  end
end
