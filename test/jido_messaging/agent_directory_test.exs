defmodule Jido.Messaging.AgentDirectoryTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    AgentDirectoryProjection,
    AgentDirectoryScope,
    Persistence.SQLite
  }

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule TestProjector do
    @behaviour Jido.Messaging.AgentDirectoryProjector

    @impl true
    def to_directory_projection(_source, %{attrs: attrs}, _opts), do: {:ok, attrs}
    def to_directory_projection(_source, %{raise: true}, _opts), do: raise("private projector failure")
  end

  setup do
    path = tmp_path("agent-directory")
    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})
    on_exit(fn -> File.rm(path) end)

    {:ok, messaging_modules: [ETSMessaging, SQLiteMessaging]}
  end

  test "scoped search returns only accessible messaging endpoints", %{messaging_modules: modules} do
    Enum.each(modules, fn messaging ->
      create_agent(messaging, "agent:one", "One")
      create_agent(messaging, "agent:two", "Two")
      create_agent(messaging, "agent:three", "Three")

      assert {:ok, first} =
               project(messaging, projection_attrs("one", "agent:one", "endpoint:one", name: "Support Guide"))

      assert {:ok, second} =
               project(
                 messaging,
                 projection_attrs("two", "agent:two", "endpoint:two",
                   name: "Billing Guide",
                   availability: :degraded,
                   capabilities: ["billing", "text"]
                 )
               )

      assert {:ok, _unbound} =
               project(messaging, projection_attrs("three", "agent:three", nil, name: "Private Guide"))

      {:ok, scope} =
        scope(messaging, %{
          "endpoint:one" => "agent:one",
          "endpoint:two" => "agent:two",
          "endpoint:not-present" => "agent:three"
        })

      assert {:ok, entries} = search(messaging, %{}, scope)
      assert Enum.map(entries, & &1.id) == Enum.sort([first.id, second.id])
      assert Enum.find(entries, &(&1.id == first.id)).invokable
      refute Enum.find(entries, &(&1.id == second.id)).invokable
      assert Enum.all?(entries, &(&1.freshness == :fresh))
      assert Enum.all?(entries, &(&1.endpoint_ref.system == "jido_messaging"))

      assert {:ok, [billing]} = search(messaging, %{capability: "BILLING"}, scope)
      assert billing.name == "Billing Guide"

      assert {:ok, [support]} = search(messaging, %{name: "support"}, scope)
      assert support.jidoka_agent_ref == %{"system" => "jidoka", "id" => "one"}
      assert support.source_revision == 1

      assert {:ok, ^support} = lookup(messaging, %{jidoka_agent_id: "one"}, scope)

      assert {:ok, generic_entries} =
               apply(messaging, :directory_search, [:agent, %{}, [scope: scope]])

      assert generic_entries == entries

      {:ok, other_scope} = scope(messaging, %{"endpoint:other" => "agent:one"})
      assert {:ok, []} = search(messaging, %{}, other_scope)
    end)
  end

  test "freshness is time-effective and does not authorize invocation", %{messaging_modules: modules} do
    Enum.each(modules, fn messaging ->
      create_agent(messaging, "agent:stale", "Stale")
      source_time = DateTime.add(DateTime.utc_now(), -120, :second)

      assert {:ok, _projection} =
               project(
                 messaging,
                 projection_attrs("stale", "agent:stale", "endpoint:stale",
                   source_updated_at: source_time,
                   fresh_for_seconds: 60,
                   verification_state: :verified
                 )
               )

      {:ok, scope} = scope(messaging, %{"endpoint:stale" => "agent:stale"})
      assert {:ok, [entry]} = search(messaging, %{}, scope)
      assert entry.freshness == :stale
      refute entry.invokable
      assert entry.verification_state == :verified
      assert {:ok, []} = search(messaging, %{invokable: true}, scope)

      assert {:ok, [still_stale]} =
               apply(messaging, :search_jidoka_agents, [%{}, scope, [now: source_time]])

      assert still_stale.freshness == :stale
      refute still_stale.invokable
    end)
  end

  test "projection revisions are idempotent, sequential, and serialized", %{messaging_modules: modules} do
    Enum.each(modules, fn messaging ->
      create_agent(messaging, "agent:revision", "Revision")
      attrs = projection_attrs("revision", "agent:revision", "endpoint:revision")

      assert {:ok, first} = project(messaging, attrs)
      assert {:ok, ^first} = project(messaging, attrs)

      assert {:error, :agent_directory_revision_conflict} =
               project(messaging, Map.put(attrs, :name, "Conflicting revision"))

      assert {:error, {:revision_gap, 1, 3}} =
               project(messaging, Map.merge(attrs, %{source_revision: 3, name: "Gap"}))

      revision_two_a = Map.merge(attrs, %{source_revision: 2, name: "Revision A"})
      revision_two_b = Map.merge(attrs, %{source_revision: 2, name: "Revision B"})

      results =
        [revision_two_a, revision_two_b]
        |> Task.async_stream(&project(messaging, &1), max_concurrency: 2, ordered: false)
        |> Enum.map(fn {:ok, result} -> result end)

      assert 1 == Enum.count(results, &match?({:ok, _projection}, &1))
      assert 1 == Enum.count(results, &(&1 == {:error, :agent_directory_revision_conflict}))

      assert {:error, {:stale_revision, 2}} = project(messaging, attrs)

      {:ok, stored} = apply(messaging, :get_jidoka_agent_projection, [first.id])
      assert stored.source_revision == 2

      revision_three =
        attrs
        |> Map.merge(%{source_revision: 3, name: stored.name, listing_state: :withdrawn})

      assert {:ok, withdrawn} = project(messaging, revision_three)
      assert withdrawn.inserted_at == first.inserted_at

      {:ok, scope} = scope(messaging, %{"endpoint:revision" => "agent:revision"})
      assert {:ok, []} = search(messaging, %{}, scope)
    end)
  end

  test "projection accepts only safe bounded Jidoka display fields", %{messaging_modules: modules} do
    Enum.each(modules, fn messaging ->
      create_agent(messaging, "agent:safe", "Safe")
      attrs = projection_attrs("safe", "agent:safe", "endpoint:safe")

      for unsafe <- [
            Map.put(attrs, :agent_spec, %{model: "private"}),
            Map.put(attrs, :instructions, "system prompt"),
            Map.put(attrs, :tools, [%{token: "secret"}]),
            Map.put(attrs, :api_key, "secret"),
            Map.put(attrs, :endpoint_ref, %{id: "endpoint:safe", credential: "secret"}),
            Map.put(attrs, :jidoka_agent_ref, %{system: :jidoka, id: "safe", controls: %{}}),
            Map.put(attrs, :invocation_summary, %{mode: :thread, approval: :unknown, prompt: "secret"}),
            Map.put(attrs, :capabilities, [%{tool: "shell"}]),
            Map.put(attrs, :description, "safe\e[31m"),
            Map.put(attrs, "name", "Duplicate name"),
            Map.put(attrs, :endpoint_ref, %Jido.Messaging.AgentDirectoryEndpointRef{system: "other", id: "bad"}),
            Map.put(attrs, :invocation_summary, %Jido.Messaging.AgentInvocationSummary{mode: :other, approval: :unknown}),
            Map.put(attrs, :fresh_for_seconds, 86_401)
          ] do
        assert {:error, :invalid_agent_directory_projection} = project(messaging, unsafe)
      end

      assert {:error, :invalid_agent_directory_projection} =
               project(messaging, Map.put(attrs, :source_updated_at, DateTime.add(DateTime.utc_now(), 301, :second)))

      assert {:ok, projection} = project(messaging, attrs)
      {:ok, scope} = scope(messaging, %{"endpoint:safe" => "agent:safe"})

      assert {:error, :invalid_agent_directory_query} =
               search(messaging, %{instructions: "anything"}, scope)

      assert {:error, :invalid_agent_directory_query} =
               search(messaging, %{availability: :invented}, scope)

      assert {:error, :agent_directory_scope_required} =
               apply(messaging, :directory_search, [:agent, %{}])

      assert {:ok, fetched} = apply(messaging, :get_jidoka_agent_projection, [projection.id])
      refute Map.has_key?(Map.from_struct(fetched), :metadata)

      adapter_attrs =
        projection_attrs("adapter", "agent:safe", "endpoint:adapter", source_revision: 1)

      assert {:ok, adapter_projection} =
               apply(messaging, :project_jidoka_agent_from, [
                 TestProjector,
                 :private_agent_spec,
                 %{attrs: adapter_attrs}
               ])

      assert adapter_projection.jidoka_agent_ref["id"] == "adapter"

      assert {:error, :agent_directory_projector_failed} =
               apply(messaging, :project_jidoka_agent_from, [TestProjector, :private_agent_spec, %{raise: true}])
    end)
  end

  test "scope keeps principal and instance boundaries", %{messaging_modules: modules} do
    Enum.each(modules, fn messaging ->
      assert {:ok, _human} =
               apply(messaging, :create_participant, [
                 %{id: "human:one", type: :human, identity: %{name: "Human"}}
               ])

      assert {:error, :agent_directory_principal_must_be_agent} =
               project(messaging, projection_attrs("human", "human:one", "endpoint:human"))

      create_agent(messaging, "agent:scope", "Scope")

      assert {:ok, _projection} =
               project(messaging, projection_attrs("scope", "agent:scope", "endpoint:scope"))

      {:ok, wrong_principal_scope} = scope(messaging, %{"endpoint:scope" => "agent:other"})
      assert {:ok, []} = search(messaging, %{}, wrong_principal_scope)

      wrong_instance_scope = AgentDirectoryScope.new!(__MODULE__, %{"endpoint:scope" => "agent:scope"})

      assert {:error, :agent_directory_scope_instance_mismatch} =
               search(messaging, %{}, wrong_instance_scope)

      assert {:error, :agent_directory_scope_instance_mismatch} =
               Jido.Messaging.Directory.search(messaging, :agent, %{}, scope: wrong_instance_scope)

      runtime = apply(messaging, :__jido_messaging__, [:runtime])

      assert {:error, :agent_directory_scope_instance_mismatch} =
               Jido.Messaging.directory_search(runtime, :agent, %{}, scope: wrong_instance_scope)
    end)
  end

  test "participant deletion removes its discovery projection", %{messaging_modules: modules} do
    Enum.each(modules, fn messaging ->
      create_agent(messaging, "agent:delete", "Delete")

      assert {:ok, projection} =
               project(messaging, projection_attrs("delete", "agent:delete", "endpoint:delete"))

      runtime = apply(messaging, :__jido_messaging__, [:runtime])
      {persistence, state} = Jido.Messaging.Runtime.get_persistence(runtime)
      assert :ok = persistence.delete_participant(state, "agent:delete")
      assert {:error, :not_found} = apply(messaging, :get_jidoka_agent_projection, [projection.id])
    end)
  end

  test "SQLite keeps projections across restart and applies scope at read time" do
    path = tmp_path("agent-directory-restart")
    {:ok, state} = SQLite.init(path: path, instance_id: "restart")

    participant = Participant.new(%{id: "agent:durable", type: :agent, identity: %{name: "Durable"}})
    assert {:ok, ^participant} = SQLite.save_participant(state, participant)

    projection =
      "durable"
      |> projection_attrs("agent:durable", "endpoint:durable")
      |> AgentDirectoryProjection.new()

    assert {:ok, stored} = SQLite.save_agent_directory_projection(state, projection)
    :ok = Sqlite3.close(state.db)

    {:ok, restarted} = SQLite.init(path: path, instance_id: "restart")
    scope = AgentDirectoryScope.new!(__MODULE__, %{"endpoint:durable" => "agent:durable"})

    assert {:ok, ^stored} = SQLite.get_agent_directory_projection(restarted, projection.id)
    assert {:ok, [entry]} = SQLite.directory_search(restarted, :agent, %{}, scope: scope)
    assert entry.id == projection.id
    assert entry.invokable

    :ok = Sqlite3.close(restarted.db)
    File.rm(path)
  end

  test "scope and public structs reject invalid data" do
    assert {:error, :invalid_agent_directory_scope} =
             AgentDirectoryScope.new(ETSMessaging, %{nil => "agent:one"})

    assert_raise ArgumentError, fn ->
      AgentDirectoryProjection.new(%{prompt: "not a projection"})
    end
  end

  defp projection_attrs(jidoka_id, principal_id, endpoint_id, overrides \\ []) do
    base = %{
      jidoka_agent_ref: %{system: :jidoka, id: jidoka_id},
      principal_id: principal_id,
      endpoint_ref: endpoint_ref(endpoint_id),
      name: "Agent #{jidoka_id}",
      description: "A safe agent directory description.",
      capabilities: ["text", "support"],
      availability: :available,
      version: "1.0.0",
      invocation_summary: %{mode: :thread, approval: :unknown},
      verification_state: :unverified,
      listing_state: :listed,
      source_revision: 1,
      source_updated_at: DateTime.utc_now(),
      fresh_for_seconds: 300
    }

    Map.merge(base, Map.new(overrides))
  end

  defp endpoint_ref(nil), do: nil
  defp endpoint_ref(endpoint_id), do: %{system: :jido_messaging, id: endpoint_id}

  defp create_agent(messaging, id, name) do
    assert {:ok, _agent} =
             apply(messaging, :create_participant, [
               %{id: id, type: :agent, identity: %{name: name}}
             ])
  end

  defp project(messaging, attrs), do: apply(messaging, :project_jidoka_agent, [attrs])
  defp scope(messaging, bindings), do: apply(messaging, :agent_directory_scope, [bindings])
  defp search(messaging, query, scope), do: apply(messaging, :search_jidoka_agents, [query, scope])
  defp lookup(messaging, query, scope), do: apply(messaging, :lookup_jidoka_agent, [query, scope])

  defp tmp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}.sqlite3")
  end
end
