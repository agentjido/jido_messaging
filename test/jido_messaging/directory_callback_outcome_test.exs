defmodule Jido.Messaging.DirectoryCallbackOutcomeTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.Participant
  alias Jido.Messaging.{AgentDirectory, AgentDirectoryProjection, AgentMessagingEndpoint, Persistence.ETS, Runtime}

  defmodule Store do
    def init(opts), do: ETS.init(opts)
    defdelegate list_bridge_configs(state, opts), to: ETS
    def get_participant(state, id), do: call(:participant, fn -> ETS.get_participant(state, id) end)

    def get_agent_messaging_endpoint(state, id),
      do: call(:endpoint, fn -> ETS.get_agent_messaging_endpoint(state, id) end)

    def save_agent_directory_projection(state, record),
      do: call(:save, fn -> ETS.save_agent_directory_projection(state, record) end)

    def get_agent_directory_projection(state, id),
      do: call(:get, fn -> ETS.get_agent_directory_projection(state, id) end)

    def list_agent_directory_projections(state, opts),
      do: call(:list, fn -> ETS.list_agent_directory_projections(state, opts) end)

    defp call(operation, fun) do
      mode =
        Agent.get_and_update(__MODULE__.Control, fn state ->
          {Map.get(state.modes, operation, :pass), %{state | calls: Map.update(state.calls, operation, 1, &(&1 + 1))}}
        end)

      case mode do
        :pass ->
          fun.()

        {:after_write, mode} ->
          result = fun.()
          Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1})
          fail(mode, result)

        mode ->
          fail(mode, nil)
      end
    end

    defp fail(:error, _), do: {:error, :directory_unavailable}
    defp fail(:raise, _), do: raise("private directory callback")
    defp fail(:throw, _), do: throw(:private_directory_callback)
    defp fail(:exit, _), do: exit(:private_directory_callback)
    defp fail(:invalid, _), do: :invalid
    defp fail(:invalid_record, _), do: {:ok, %{id: "invalid"}}
    defp fail({:result, result}, _), do: result
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{modes: %{}, calls: %{}, writes: 0} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)
    participant = Participant.new(%{id: "owned-agent", type: :agent})
    {:ok, ^participant} = ETS.save_participant(state, participant)

    endpoint =
      AgentMessagingEndpoint.new(%{
        id: "owned-endpoint",
        principal_id: participant.id,
        jidoka_agent_ref: %{system: :jidoka, id: "owned"}
      })

    {:ok, ^endpoint} = ETS.save_agent_messaging_endpoint(state, endpoint)
    attrs = attrs()
    projection = AgentDirectoryProjection.new(attrs)
    {:ok, ^projection} = ETS.save_agent_directory_projection(state, projection)
    {:ok, scope} = Instance.agent_directory_scope(%{endpoint.id => participant.id})

    {:ok,
     runtime: runtime,
     state: state,
     attrs: attrs,
     participant: participant,
     endpoint: endpoint,
     projection: projection,
     scope: scope}
  end

  for operation <- [:participant, :endpoint, :save],
      mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record] do
    test "projection #{operation} #{mode} has a safe outcome and no record replacement", context do
      set_mode(unquote(operation), unquote(mode))
      expected = expected(unquote(mode))

      assert {:error, ^expected} =
               Instance.project_jidoka_agent(
                 Map.merge(context.attrs, %{source_revision: 2, name: "Next Complete Name"})
               )

      assert_records(context, context.projection)
      assert Agent.get(Store.Control, &Map.get(&1.calls, :save, 0)) == if(unquote(operation) == :save, do: 1, else: 0)
    end
  end

  for operation <- [:get, :list], mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record] do
    test "directory #{operation} #{mode} is a failure and cannot return partial discovery", context do
      set_mode(unquote(operation), unquote(mode))
      expected = expected(unquote(mode))

      result =
        if unquote(operation) == :get,
          do: Instance.get_jidoka_agent_projection(context.projection.id),
          else: Instance.search_jidoka_agents(%{}, context.scope)

      assert {:error, ^expected} = result
      assert_records(context, context.projection)
    end
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "projection #{mode} after-write outcome retains one complete accepted revision", context do
      set_mode(:save, {:after_write, unquote(mode)})
      expected = expected(unquote(mode))
      next = Map.merge(context.attrs, %{source_revision: 2, name: "Next Complete Name"})
      assert {:error, ^expected} = Instance.project_jidoka_agent(next)
      assert Agent.get(Store.Control, & &1.writes) == 1
      assert {:ok, stored} = ETS.get_agent_directory_projection(context.state, context.projection.id)
      assert stored.source_revision == 2
      assert stored.name == "Next Complete Name"
      assert stored.inserted_at == context.projection.inserted_at
      set_mode(:save, :pass)
      assert {:ok, ^stored} = Instance.project_jidoka_agent(next)
      assert_records(context, stored)
    end
  end

  test "foreign participant and endpoint identities cannot accept a directory projection", context do
    for {operation, value} <- [
          {:participant, %{context.participant | id: "foreign"}},
          {:endpoint, %{context.endpoint | id: "foreign"}}
        ] do
      set_mode(operation, {:result, {:ok, value}})
      assert {:error, :persistence_failed} = Instance.project_jidoka_agent(Map.put(context.attrs, :source_revision, 2))
      assert_records(context, context.projection)
      set_mode(operation, :pass)
    end
  end

  test "foreign get identity and a mixed invalid list cannot yield a successful partial result", context do
    set_mode(:get, {:result, {:ok, %{context.projection | id: "foreign"}}})
    assert {:error, :persistence_failed} = Instance.get_jidoka_agent_projection(context.projection.id)

    for invalid <- [
          nil,
          %{},
          %{context.projection | fresh_until: nil},
          %{context.projection | endpoint_ref: %{id: "owned-endpoint"}}
        ] do
      set_mode(:list, {:result, {:ok, [context.projection, invalid]}})
      assert {:error, :persistence_failed} = Instance.search_jidoka_agents(%{}, context.scope)

      assert {:error, :persistence_failed} =
               AgentDirectory.filter_projections([context.projection, invalid], %{}, context.scope, [])
    end

    assert_records(context, context.projection)
  end

  test "a semantic save mismatch cannot report a different revision as accepted", context do
    for record <- [
          %{context.projection | source_revision: 2, name: "Foreign Name"},
          %{context.projection | id: "foreign", source_revision: 2},
          %{context.projection | principal_id: "foreign", source_revision: 2}
        ] do
      set_mode(:save, {:result, {:ok, record}})

      assert {:error, :persistence_failed} =
               Instance.project_jidoka_agent(
                 Map.merge(context.attrs, %{source_revision: 2, name: "Next Complete Name"})
               )

      assert_records(context, context.projection)
    end
  end

  defp attrs do
    %{
      jidoka_agent_ref: %{system: :jidoka, id: "owned"},
      principal_id: "owned-agent",
      endpoint_ref: %{system: :jido_messaging, id: "owned-endpoint"},
      name: "Complete Agent Name",
      description: "Complete display",
      capabilities: ["text"],
      availability: :available,
      version: "1",
      invocation_summary: %{mode: :thread, approval: :unknown},
      verification_state: :unverified,
      listing_state: :listed,
      source_revision: 1,
      source_updated_at: DateTime.utc_now(),
      fresh_for_seconds: 300
    }
  end

  defp set_mode(operation, mode), do: Agent.update(Store.Control, &%{&1 | modes: Map.put(&1.modes, operation, mode)})
  defp expected(:error), do: :directory_unavailable
  defp expected(_), do: :persistence_failed

  defp assert_records(context, projection) do
    assert {:ok, ^projection} = ETS.get_agent_directory_projection(context.state, context.projection.id)
    assert {:ok, participant} = ETS.get_participant(context.state, context.participant.id)
    assert participant == context.participant
    assert {:ok, endpoint} = ETS.get_agent_messaging_endpoint(context.state, context.endpoint.id)
    assert endpoint == context.endpoint
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert Jido.Messaging.TestHelpers.runtime_entry_count(context.runtime) == 0
    assert Instance.count_agents() == 0
  end
end
