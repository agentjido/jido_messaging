defmodule JidoMessaging.Specs.Story00RuntimeTopologyAndSLOsTest do
  use ExUnit.Case, async: true

  @story_file "specs/stories/00-runtime-topology-and-slos.md"
  @traceability_file "specs/stories/00_traceability_matrix.md"
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

    assert story =~ "## Canonical Runtime Topology"

    assert story =~
             "| Subsystem | Owner Process | Supervisor | Strategy | Restart Intensity | Failure Domain Intent |"

    assert story =~ "Root runtime tree"
    assert story =~ "Room domain"
    assert story =~ "Agent domain"
    assert story =~ "Instance domain"
    assert story =~ "Per-instance subtree"
    assert story =~ "Outbound gateway domain"
    assert story =~ "Session routing domain"
    assert story =~ "Operations domain"
  end

  test "crash policy matrix defines fatal, recoverable, and degraded classes with handling guidance" do
    story = File.read!(@story_file)

    assert story =~ "## Crash Policy Matrix"

    assert story =~
             "| Failure Mode | Class | Immediate Handling Guidance | Supervisor Action | Required Telemetry Dimensions |"

    assert story =~ "| Runtime boot config invalid"
    assert story =~ "| Channel listener transient disconnect or timeout"
    assert story =~ "| Poison message / invalid payload in ingest or outbound serialization"
    assert story =~ "`fatal`"
    assert story =~ "`recoverable`"
    assert story =~ "`degraded`"
  end

  test "slo baselines and pressure thresholds are mapped to telemetry dimensions" do
    story = File.read!(@story_file)

    assert story =~ "## SLO Baselines And Pressure Thresholds"

    assert story =~
             "| Capability | SLI / Metric | Baseline Target | Pressure Thresholds | Telemetry Event | Required Dimensions |"

    assert story =~ "Ingest decision latency"
    assert story =~ "Outbound enqueue latency"
    assert story =~ "Queue pressure safety"
    assert story =~ "[:jido_messaging, :pressure, :transition]"
  end

  test "partitioning guidance exists for expected hot-path workers" do
    story = File.read!(@story_file)

    assert story =~ "## Partitioning And Sharding Guidance"

    assert story =~
             "| Worker Domain | Unit Of Concurrency | Partition / Shard Key | Baseline Partitioning Rule | Notes |"

    assert story =~ "Room state (`RoomServer`)"
    assert story =~ "Instance runtime (`InstanceServer` + channel listeners)"
    assert story =~ "Outbound gateway partitions (Story 03+)"
    assert story =~ "Session routing manager (Story 06+)"
    assert story =~ "Onboarding state machine (Story 09+)"
    assert story =~ "Dead-letter replay workers (Story 11+)"
  end

  test "architecture review gate explicitly blocks missing topology or crash semantics" do
    story = File.read!(@story_file)

    assert story =~ "## Architecture Review Gate (Blocking)"
    assert story =~ "must not merge"
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
end
