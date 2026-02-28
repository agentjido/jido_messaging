defmodule Jido.Messaging.Specs.Story00RuntimeTopologyAndSLOsTest do
  use ExUnit.Case, async: true
  @moduletag :story

  @story_file "specs/stories/00-runtime-topology-and-slos.md"
  @traceability_file "specs/stories/00_traceability_matrix.md"
  @topology_headers [
    "Subsystem",
    "Owner Process",
    "Supervisor",
    "Strategy",
    "Restart Intensity",
    "Failure Domain Intent"
  ]
  @crash_policy_headers [
    "Failure Mode",
    "Class",
    "Immediate Handling Guidance",
    "Supervisor Action",
    "Required Telemetry Dimensions"
  ]
  @slo_headers [
    "Capability",
    "SLI / Metric",
    "Baseline Target",
    "Pressure Thresholds",
    "Telemetry Event",
    "Required Dimensions"
  ]
  @partition_headers [
    "Worker Domain",
    "Unit Of Concurrency",
    "Partition / Shard Key",
    "Baseline Partitioning Rule",
    "Notes"
  ]
  @downstream_story_files [
    "specs/stories/01-channel-contract-v2.md",
    "specs/stories/02-instance-lifecycle-runtime.md",
    "specs/stories/03-outbound-gateway.md",
    "specs/stories/04-ingest-policy-pipeline.md",
    "specs/stories/05-security-boundary.md",
    "specs/stories/06-session-routing-manager.md",
    "specs/stories/07-media-pipeline.md",
    "specs/stories/08-command-mention-normalization.md",
    "specs/stories/09-directory-onboarding.md",
    "specs/stories/10-plugin-manifest-discovery.md",
    "specs/stories/11-resilience-ops.md"
  ]

  test "canonical topology matrix defines owner process, strategy, and restart intensity per subsystem" do
    story = File.read!(@story_file)
    section = section!(story, "Canonical Runtime Topology")
    {headers, rows} = first_table!(section)

    assert story =~ "## Canonical Runtime Topology"
    assert headers == @topology_headers

    expected_subsystems = [
      "Root runtime tree",
      "Room domain",
      "Agent domain",
      "Instance domain",
      "Per-instance subtree",
      "Outbound gateway domain",
      "Session routing domain",
      "Operations domain"
    ]

    assert length(rows) >= length(expected_subsystems)

    for expected <- expected_subsystems do
      assert Enum.any?(rows, fn [subsystem | _rest] -> String.contains?(subsystem, expected) end)
    end

    for row <- rows do
      assert length(row) == length(@topology_headers)

      [subsystem, owner, supervisor, strategy, restart_intensity, failure_domain_intent] = row

      assert subsystem != ""
      assert owner != ""
      assert supervisor != ""
      assert Regex.match?(~r/^:[a-z_]+$/, unwrap_inline_code(strategy))
      assert Regex.match?(~r/^\d+\/\d+s$/, unwrap_inline_code(restart_intensity))
      assert failure_domain_intent != ""
    end
  end

  test "crash policy matrix defines fatal, recoverable, and degraded classes with handling guidance" do
    story = File.read!(@story_file)
    section = section!(story, "Crash Policy Matrix")
    {headers, rows} = first_table!(section)

    assert story =~ "## Crash Policy Matrix"
    assert headers == @crash_policy_headers

    assert Enum.any?(rows, fn [failure_mode | _rest] ->
             String.contains?(failure_mode, "Runtime boot config invalid")
           end)

    assert Enum.any?(rows, fn [failure_mode | _rest] ->
             String.contains?(failure_mode, "Channel listener transient disconnect or timeout")
           end)

    assert Enum.any?(rows, fn [failure_mode | _rest] ->
             String.contains?(
               failure_mode,
               "Poison message / invalid payload in ingest or outbound serialization"
             )
           end)

    for row <- rows do
      assert length(row) == length(@crash_policy_headers)

      [failure_mode, classification, guidance, supervisor_action, required_dimensions] = row

      assert failure_mode != ""
      assert unwrap_inline_code(classification) in ["fatal", "recoverable", "degraded"]
      assert guidance != ""
      assert supervisor_action != ""
      assert required_dimensions != ""
    end

    classes = rows |> Enum.map(&Enum.at(&1, 1)) |> Enum.map(&unwrap_inline_code/1) |> MapSet.new()
    assert classes == MapSet.new(["fatal", "recoverable", "degraded"])
  end

  test "slo baselines and pressure thresholds are mapped to telemetry dimensions" do
    story = File.read!(@story_file)
    section = section!(story, "SLO Baselines And Pressure Thresholds")
    {headers, rows} = first_table!(section)

    assert story =~ "## SLO Baselines And Pressure Thresholds"
    assert headers == @slo_headers

    assert Enum.any?(rows, fn [capability | _rest] ->
             String.contains?(capability, "Ingest decision latency")
           end)

    assert Enum.any?(rows, fn [capability | _rest] ->
             String.contains?(capability, "Outbound enqueue latency")
           end)

    assert Enum.any?(rows, fn [capability | _rest] ->
             String.contains?(capability, "Queue pressure safety")
           end)

    for row <- rows do
      assert length(row) == length(@slo_headers)

      [capability, metric, target, thresholds, event_name, required_dimensions] = row

      assert capability != ""
      assert metric != ""
      assert target != ""
      assert thresholds != ""
      assert String.starts_with?(unwrap_inline_code(event_name), "[:jido_messaging")
      assert required_dimensions != ""
    end

    [_, _, _, pressure_thresholds, pressure_event, _] =
      Enum.find(rows, fn [capability | _rest] ->
        String.contains?(capability, "Queue pressure safety")
      end)

    assert String.contains?(pressure_thresholds, "warn")
    assert String.contains?(pressure_thresholds, "degraded")
    assert String.contains?(pressure_thresholds, "shed")
    assert unwrap_inline_code(pressure_event) == "[:jido_messaging, :pressure, :transition]"

    assert story =~ "### Pressure Level Contract"
    assert story =~ "- `normal`"
    assert story =~ "- `warn`"
    assert story =~ "- `degraded`"
    assert story =~ "- `shed`"
  end

  test "partitioning guidance exists for expected hot-path workers" do
    story = File.read!(@story_file)
    section = section!(story, "Partitioning And Sharding Guidance")
    {headers, rows} = first_table!(section)

    assert story =~ "## Partitioning And Sharding Guidance"
    assert headers == @partition_headers

    expected_worker_domains = [
      "Room state (`RoomServer`)",
      "Instance runtime (`InstanceServer` + channel listeners)",
      "Ingest policy workers (Story 04+)",
      "Outbound gateway partitions (Story 03+)",
      "Session routing manager (Story 06+)",
      "Onboarding state machine (Story 09+)",
      "Dead-letter replay workers (Story 11+)"
    ]

    assert length(rows) >= length(expected_worker_domains)

    for domain <- expected_worker_domains do
      assert Enum.any?(rows, fn [worker_domain | _rest] -> worker_domain == domain end)
    end

    for row <- rows do
      assert length(row) == length(@partition_headers)

      [worker_domain, unit_of_concurrency, shard_key, partition_rule, notes] = row

      assert worker_domain != ""
      assert unit_of_concurrency != ""
      assert shard_key != ""
      assert partition_rule != ""
      assert notes != ""
    end
  end

  test "architecture review gate explicitly blocks missing topology or crash semantics" do
    story = File.read!(@story_file)
    section = section!(story, "Architecture Review Gate (Blocking)")

    assert story =~ "## Architecture Review Gate (Blocking)"
    assert section =~ "blocked unless all are explicit"
    assert section =~ "1. Owner process and supervisor name."
    assert section =~ "2. Supervisor strategy and restart intensity (`max_restarts/max_seconds`)."

    assert section =~
             "3. Crash policy class for each major failure mode (`fatal`/`recoverable`/`degraded`)."

    assert section =~ "4. Partition/shard key and scaling rule for hot path."
    assert section =~ "5. SLO target and pressure thresholds."
    assert section =~ "6. Telemetry event names plus required dimensions."
    assert section =~ "must not merge"
  end

  test "traceability matrix includes ST-OCM-000 mapping to story 00 spec" do
    traceability = File.read!(@traceability_file)

    assert traceability =~
             "| `ST-OCM-000` | `12_openclaw_architecture_gap_stories.md` | `Runtime topology and telemetry contracts` | R1,R2,R3 | specs/stories/00-runtime-topology-and-slos.md |"
  end

  test "all downstream stories explicitly depend on Story 00 runtime contract" do
    for story_file <- @downstream_story_files do
      contents = File.read!(story_file)
      assert contents =~ "- Story 00: Runtime Topology And SLOs."
    end
  end

  defp section!(story, heading) do
    pattern = ~r/^## #{Regex.escape(heading)}\n(.*?)(?=^## |\z)/ms

    case Regex.run(pattern, story, capture: :all_but_first) do
      [section] -> section
      _ -> flunk("missing section: #{heading}")
    end
  end

  defp first_table!(section) do
    case Regex.run(~r/^\|(.+)\|\n^\|(?:\s*:?-+:?\s*\|)+\n((?:^\|.*\|\n?)*)/m, section, capture: :all_but_first) do
      [header_row, body] ->
        headers = parse_markdown_row("|#{header_row}|")

        rows =
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_markdown_row/1)
          |> Enum.reject(&(&1 == []))

        {headers, rows}

      _ ->
        flunk("missing markdown table")
    end
  end

  defp parse_markdown_row(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp unwrap_inline_code(value) do
    value
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
  end
end
