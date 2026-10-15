defmodule Jido.Messaging.DirectoryInputBoundaryTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{AgentDirectoryProjection, AgentDirectoryScope}

  defmodule ETSInstance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule SQLiteInstance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite, runtime_profile: :core
  end

  setup do
    path = Path.join(System.tmp_dir!(), "directory-input-#{System.unique_integer([:positive])}.sqlite3")
    start_supervised!(ETSInstance)
    start_supervised!({SQLiteInstance, persistence_opts: [path: path]})
    on_exit(fn -> File.rm(path) end)
    {:ok, instances: [ETSInstance, SQLiteInstance]}
  end

  test "invalid projection fields preserve the complete stored record and add no authority", context do
    for instance <- context.instances do
      {:ok, _} = instance.create_participant(%{id: "directory-owner", type: :agent})
      valid = attrs()
      assert {:ok, stored} = instance.project_jidoka_agent(valid)

      for {field, values} <- [
            principal_id: [nil, 1, "", "two ids", "id\0bad", <<255>>, String.duplicate("x", 513)],
            name: [nil, 1, "", "bad\0name", <<255>>, String.duplicate("x", 257)],
            description: [1, self(), "bad\0description", <<255>>, String.duplicate("x", 1_025)],
            version: [nil, 1, "", "two versions", <<255>>, String.duplicate("x", 513)],
            capabilities: [nil, :text, [""], ["bad code"], [String.duplicate("x", 129)], Enum.map(1..33, &"code#{&1}")],
            availability: [:invalid, "invalid", 1],
            verification_state: [:invalid, "invalid", 1],
            listing_state: [:invalid, "invalid", 1],
            source_revision: [nil, 0, -1, "1"],
            source_updated_at: [nil, "now", DateTime.add(DateTime.utc_now(), 600, :second)],
            fresh_for_seconds: [nil, 0, -1, 86_401],
            jidoka_agent_ref: [nil, %{}, %{system: :foreign, id: "owned"}, %{system: :jidoka, id: "bad id"}],
            endpoint_ref: [1, %{system: :foreign, id: "endpoint"}, %{system: :jido_messaging, id: "bad id"}],
            invocation_summary: [nil, 1, %{mode: :invalid}, %{mode: :thread, approval: 1}]
          ],
          value <- values do
        invalid =
          valid |> Map.put(field, value) |> Map.put(:source_revision, if(field == :source_revision, do: value, else: 2))

        assert {:error, :invalid_agent_directory_projection} = instance.project_jidoka_agent(invalid)
        assert {:ok, ^stored} = instance.get_jidoka_agent_projection(stored.id)
        assert_no_authority(instance)
      end
    end
  end

  test "maximum valid display fields retain all content and empty optional text", context do
    for instance <- context.instances do
      {:ok, _} = instance.create_participant(%{id: "directory-owner", type: :agent})
      name = String.duplicate("é", 128)
      description = String.duplicate("é", 512)
      capabilities = Enum.map(1..32, &"capability#{&1}")
      valid = Map.merge(attrs(), %{name: name, description: description, capabilities: capabilities})
      assert {:ok, stored} = instance.project_jidoka_agent(string_keys(valid))
      assert stored.name == name
      assert stored.description == description
      assert stored.capabilities == Enum.sort(capabilities)
      assert {:ok, ^stored} = instance.get_jidoka_agent_projection(stored.id)

      for description <- [nil, "   "] do
        record = AgentDirectoryProjection.new(Map.put(valid, :description, description))
        assert record.description == nil
        assert record.name == name
        assert record.capabilities == Enum.sort(capabilities)
      end

      assert_no_authority(instance)
    end
  end

  test "invalid directory query fields do not broaden a valid scope", context do
    for instance <- context.instances do
      {:ok, _} = instance.create_participant(%{id: "directory-owner", type: :agent})
      {:ok, _} = instance.project_jidoka_agent(attrs())
      {:ok, scope} = instance.agent_directory_scope(%{"endpoint-owned" => "directory-owner"})

      for query <- [
            %{name: self()},
            %{name: String.duplicate("x", 513)},
            %{invokable: "true"},
            %{availability: 1},
            %{verification_state: :invalid},
            %{"name" => "Foreign", name: "Agent"},
            %{token: "private"}
          ] do
        assert {:error, :invalid_agent_directory_query} = instance.search_jidoka_agents(query, scope)
      end

      for limit <- [0, -1, nil, "1"] do
        assert {:error, :invalid_agent_directory_limit} = instance.search_jidoka_agents(%{}, scope, limit: limit)
      end

      assert {:ok, []} = instance.search_jidoka_agents(%{}, scope)
      assert_no_authority(instance)
    end
  end

  test "scope rejects identifiers that become the same endpoint after normalization" do
    for pairs <- [
          %{"endpoint" => "principal-owned", " endpoint " => "principal-foreign"},
          %{"endpoint" => "principal-owned", "endpoint " => "principal-owned"}
        ] do
      assert {:error, :invalid_agent_directory_scope} = AgentDirectoryScope.new(ETSInstance, pairs)
    end
  end

  defp attrs do
    %{
      jidoka_agent_ref: %{system: :jidoka, id: "owned"},
      principal_id: "directory-owner",
      endpoint_ref: nil,
      name: "Owned Agent",
      description: "Complete safe description",
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

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp assert_no_authority(instance) do
    runtime = instance.__jido_messaging__(:runtime)
    assert Jido.Messaging.TestHelpers.runtime_entry_count(runtime) == 0
    assert instance.count_agents() == 0
    assert {:ok, []} = instance.list_principal_grants("directory-owner")
    assert {:ok, []} = instance.list_rooms()
  end
end
