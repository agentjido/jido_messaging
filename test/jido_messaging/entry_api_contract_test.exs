defmodule Jido.Messaging.EntryApiContractTest do
  use ExUnit.Case, async: true

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.Postgres, runtime_profile: :core
  end

  @contracts __DIR__
             |> Path.join("../fixtures/entry_api_contracts_v1.json")
             |> File.read!()
             |> Jason.decode!()

  test "entry, ingest, and generated instance exports retain the C2 public API" do
    for contract <- @contracts["modules"] do
      module = if contract["module"] == "instance", do: Instance, else: Module.concat([contract["module"]])
      Code.ensure_loaded!(module)
      assert exports(module, :functions) == contract["functions"]
      assert exports(module, :macros) == contract["macros"]
    end
  end

  test "generated instance retains runtime names and configuration" do
    assert Instance.__jido_messaging__(:persistence) == Jido.Messaging.Persistence.Postgres
    assert Instance.__jido_messaging__(:runtime) == Module.concat(Instance, :Runtime)
    assert Instance.__jido_messaging__(:room_supervisor) == Module.concat(Instance, :RoomSupervisor)
    assert Instance.__jido_messaging__(:agent_supervisor) == Module.concat(Instance, :AgentSupervisor)
    assert Instance.child_spec([]).start == {Instance, :start_link, [[]]}
  end

  defp exports(module, kind), do: Enum.map(module.__info__(kind), fn {name, arity} -> "#{name}/#{arity}" end)
end
