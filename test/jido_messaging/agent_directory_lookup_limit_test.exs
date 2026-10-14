defmodule Jido.Messaging.AgentDirectoryLookupLimitTest do
  use ExUnit.Case, async: true

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  test "a lookup search limit cannot hide another scoped agent" do
    start_supervised!(Instance)

    pairs =
      for index <- 1..2, into: %{} do
        principal = "principal-#{index}"
        endpoint = "endpoint-#{index}"
        {:ok, _} = Instance.create_participant(%{id: principal, type: :agent})

        {:ok, _} =
          Instance.project_jidoka_agent(%{
            jidoka_agent_ref: %{system: :jidoka, id: "agent-#{index}"},
            principal_id: principal,
            endpoint_ref: %{system: :jido_messaging, id: endpoint},
            name: "Support",
            capabilities: ["support"],
            availability: :available,
            version: "1",
            invocation_summary: %{mode: :thread, approval: :unknown},
            source_revision: 1,
            source_updated_at: DateTime.utc_now(),
            fresh_for_seconds: 300
          })

        {endpoint, principal}
      end

    {:ok, scope} = Instance.agent_directory_scope(pairs)
    assert {:ok, [_]} = Instance.search_jidoka_agents(%{capability: "support"}, scope, limit: 1)
    assert {:error, {:ambiguous, entries}} = Instance.lookup_jidoka_agent(%{capability: "support"}, scope, limit: 1)
    assert length(entries) == 2

    assert {:error, {:ambiguous, ^entries}} =
             Instance.directory_lookup(:agent, %{capability: "support"}, scope: scope, limit: 1)

    assert {:error, {:ambiguous, ^entries}} =
             Jido.Messaging.Directory.lookup(Instance, :agent, %{capability: "support"}, scope: scope, limit: 1)
  end
end
