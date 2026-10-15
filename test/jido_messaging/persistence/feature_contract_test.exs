defmodule Jido.Messaging.Persistence.FeatureContractTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Persistence
  alias Jido.Messaging.Persistence.Contracts

  @fixture Path.expand("../../fixtures/stored_records_v1.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "the aggregate retains all 93 signatures and optional callbacks" do
    assert callback_specs(Persistence) == @fixture["callbacks"]

    optional =
      Persistence.behaviour_info(:optional_callbacks)
      |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
      |> Enum.sort()

    assert optional == @fixture["optional_callbacks"]
  end

  test "feature groups partition the aggregate without changing callback signatures" do
    grouped = Enum.flat_map(Contracts.all(), &Map.to_list(callback_specs(&1)))
    assert length(grouped) == 93
    assert Map.new(grouped) == @fixture["callbacks"]

    for group <- Contracts.all() do
      assert group.behaviour_info(:optional_callbacks) == []
    end
  end

  for {adapter, excluded, count} <- [
        {Persistence.ETS, [Contracts.Transactions], 91},
        {Persistence.SQLite, [], 93},
        {Persistence.Postgres,
         [
           Contracts.ExternalIdentity,
           Contracts.AgentRouting,
           Contracts.AgentDirectory,
           Contracts.Credentials,
           Contracts.Continuity,
           Contracts.TrustEvidence,
           Contracts.Activity
         ], 61}
      ] do
    test "#{adapter} implements every declared feature and claims no unsupported group" do
      adapter = unquote(adapter)
      excluded = unquote(excluded)
      expected = Contracts.all() -- excluded
      assert Enum.sort(Contracts.declared(adapter)) == Enum.sort(expected)

      for group <- expected do
        assert Contracts.missing_callbacks(adapter, group) == [], inspect(group)
      end

      for group <- excluded do
        assert Contracts.missing_callbacks(adapter, group) == Enum.sort(group.behaviour_info(:callbacks))
      end

      implemented = Enum.flat_map(expected, & &1.behaviour_info(:callbacks))
      assert length(implemented) == unquote(count)
    end
  end

  defp callback_specs(module) do
    {:ok, callbacks} = Code.Typespec.fetch_callbacks(module)

    Map.new(callbacks, fn {{name, arity}, specs} ->
      {"#{name}/#{arity}", Enum.map(specs, &(Code.Typespec.spec_to_quoted(name, &1) |> Macro.to_string()))}
    end)
  end
end
