defmodule Jido.Messaging.ChatRequestRetentionTest do
  use ExUnit.Case, async: false
  import Jido.Messaging.TestHelpers

  alias Jido.Chat.{Resources, Signal.SendMessage}
  alias Jido.Chat.Errors.Contract
  alias Jido.Chat.Operations.Failure
  alias Jido.Messaging.{BridgeConfig, ProviderCall, RequestStore, Runtime}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: {:error, :unused}
    @impl true
    def capabilities, do: %{send_message: :native, fetch_media: :native}
    @impl true
    def send_message(room, text, opts) do
      send(opts[:probe], {:provider, self(), text, opts})

      case text do
        "degraded" -> {:error, {:unsupported_method, :old}}
        "tagged" -> {:error, :queue_full}
        "large" -> {:ok, %{id: "large", room_id: room, text: String.duplicate("large", 60_000)}}
        "held" -> receive do: (:release -> {:ok, %{id: "held", room_id: room, text: text}})
        _ -> {:ok, %{id: text, room_id: room, text: text}}
      end
    end

    @impl true
    def fetch_media(value, _opts), do: {:ok, value}
  end

  setup do
    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, binding} = Runtime.ensure_binding(runtime, Adapter, "owned", probe: self())
    [{RequestStore, store}] = :ets.lookup(Runtime.request_table(runtime), RequestStore)
    %{runtime: runtime, binding: binding, store: store}
  end

  test "old successes and failure metadata replay from disk without a second ETS index", context do
    success = request("old-success", "success")
    degraded = request("old-failure", "degraded")
    tagged = request("old-tag", "tagged")
    assert {:ok, original} = Jido.Chat.execute(context.binding, success)
    assert {:ok, failure} = Jido.Chat.execute(context.binding, degraded)
    assert {:ok, tag} = Jido.Chat.execute(context.binding, tagged)
    assert Failure.class(context.binding, failure) == :degraded
    assert Failure.reason_tag(context.binding, tag) == :queue_full

    for index <- 1..1_001 do
      assert {:ok, _} = Jido.Chat.execute(context.binding, request("new-#{index}", "new"))
    end

    {:ok, stats} = RequestStore.call(context.store, :stats)
    assert stats.cache_entries == 1_000
    assert stats.cache_bytes <= 16 * 1_024 * 1_024
    assert stats.disk_entries == 1_006
    assert :ets.info(context.binding.resources, :size) == 1
    runtime_pid = Process.whereis(context.runtime)
    restart_store(context.store)
    assert {:ok, ^original} = Jido.Chat.execute(context.binding, success)
    assert {:ok, ^failure} = Jido.Chat.execute(context.binding, degraded)
    assert {:ok, ^tag} = Jido.Chat.execute(context.binding, tagged)
    assert Failure.class(context.binding, failure) == :degraded
    assert Failure.reason_tag(context.binding, tag) == :queue_full
    assert Process.whereis(context.runtime) == runtime_pid
    assert length(drain_calls()) == 1_004
    refute_received {:provider, _, _, _}
  end

  test "Chat and Messaging share a binding claim before either provider path can repeat", context do
    direct = Task.async(fn -> Jido.Chat.execute(context.binding, request("shared", "held")) end)
    assert_receive {:provider, provider, "held", opts}, 1_000
    refute Keyword.has_key?(opts, :request_store)

    assert {:error, %Contract{code: :request_in_progress}} =
             ProviderCall.operation(Adapter, :send_message, %{"room_id" => "room", "text" => "held"},
               binding: context.binding,
               request_id: "shared"
             )

    send(provider, :release)
    assert {:ok, result} = Task.await(direct)

    assert {:ok, translated} =
             ProviderCall.operation(Adapter, :send_message, %{"room_id" => "room", "text" => "held"},
               binding: context.binding,
               request_id: "shared"
             )

    assert translated["id"] == result.data["result"]["id"]
    refute_received {:provider, _, _, _}
  end

  test "binding generations do not share claims and external bindings keep their owner", context do
    assert {:ok, old_result} = Jido.Chat.execute(context.binding, request("same", "old"))
    config = BridgeConfig.new(%{id: "owned", adapter_module: Adapter, revision: 1})
    {:ok, replacement} = Runtime.ensure_binding(context.runtime, Adapter, "owned", probe: self(), bridge_config: config)
    assert replacement.resources != context.binding.resources
    assert {:ok, new_result} = Jido.Chat.execute(replacement, request("same", "new"))
    assert new_result != old_result
    assert {:ok, ^old_result} = Jido.Chat.execute(context.binding, request("same", "old"))
    assert :ets.info(replacement.resources, :owner) == Process.whereis(context.runtime)

    {:ok, external} = Jido.Chat.bind(Adapter, id: "external", probe: self())
    assert :ok = Runtime.register_binding(context.runtime, external)
    assert {:ok, ^external} = Runtime.ensure_binding(context.runtime, Adapter, "external", [])
    assert :ets.info(external.resources, :owner) == self()
    assert :ets.info(external.resources, :size) == 0
    assert {:ok, _} = Jido.Chat.execute(external, request("external", "external"))
    assert [{{:request, "external"}, _, {:done, _}}] = :ets.tab2list(external.resources)
  end

  test "replay preserves resource owners, expiry, cancellation, and failed state", context do
    for {status, expected} <- [cancelled: :resource_cancelled, failed: :resource_failure, expired: :resource_expired] do
      {:ok, input} = Resources.put(context.binding, "media", "bytes", [])
      request = Jido.Chat.Signal.FetchMedia.new!(%{"request_id" => "media-#{status}", "media_ref" => input})
      assert {:ok, result} = Jido.Chat.execute(context.binding, request)
      ref = result.data["result"]["resource_ref"]
      assert {:ok, "bytes"} = Resources.resolve(context.binding, ref)
      task = Task.async(fn -> Resources.resolve(context.binding, ref) end)
      assert {:error, %Contract{code: :resource_owner_mismatch}} = Task.await(task)

      case status do
        :cancelled ->
          assert :ok = Resources.cancel(context.binding, ref)

        :failed ->
          assert :ok = Resources.fail(context.binding, ref)

        :expired ->
          [{key, owner, kind, value, _, active}] = :ets.lookup(context.binding.resources, {:resource, ref["id"]})

          :ets.insert(
            context.binding.resources,
            {key, owner, kind, value, System.monotonic_time(:millisecond) - 1, active}
          )
      end

      before = :ets.lookup(context.binding.resources, {:resource, ref["id"]})
      restart_store(context.store)
      assert {:ok, ^result} = Jido.Chat.execute(context.binding, request)
      assert :ets.lookup(context.binding.resources, {:resource, ref["id"]}) == before
      assert {:error, %Contract{code: ^expected}} = Resources.resolve(context.binding, ref)
    end

    task =
      Task.async(fn ->
        {:ok, input} = Resources.put(context.binding, "media", "bytes", [])
        request = Jido.Chat.Signal.FetchMedia.new!(%{"request_id" => "dead-owner", "media_ref" => input})
        {:ok, result} = Jido.Chat.execute(context.binding, request)
        {request, result}
      end)

    {request, result} = Task.await(task)
    assert {:ok, ^result} = Jido.Chat.execute(context.binding, request)

    assert {:error, %Contract{code: :resource_expired}} =
             Resources.resolve(context.binding, result.data["result"]["resource_ref"])
  end

  test "store write failure closes owned Chat admission before and after an effect", context do
    {:ok, stats} = RequestStore.call(context.store, :stats)
    :ok = Exqlite.Sqlite3.execute(:sys.get_state(stats.worker).db, "PRAGMA query_only=ON")

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             Jido.Chat.execute(context.binding, request("no-effect", "no-effect"))

    refute_received {:provider, _, _, _}
    wait_for_worker(context.store, stats.worker)

    request = request("uncertain", "held")
    task = Task.async(fn -> Jido.Chat.execute(context.binding, request) end)
    assert_receive {:provider, provider, "held", _}, 1_000
    {:ok, stats} = RequestStore.call(context.store, :stats)
    :ok = Exqlite.Sqlite3.execute(:sys.get_state(stats.worker).db, "PRAGMA query_only=ON")
    send(provider, :release)
    assert {:error, %Contract{code: :request_outcome_unknown}} = Task.await(task)
    wait_for_worker(context.store, stats.worker)
    assert {:error, %Contract{code: :request_outcome_unknown}} = Jido.Chat.execute(context.binding, request)
    refute_received {:provider, _, _, _}
  end

  test "failure metadata replacement removes its old cache value", context do
    result = %{id: "replaced", data: %{"retryable" => true}}
    :ok = Failure.remember(context.binding, result, :recoverable, :timeout)
    assert Failure.class(context.binding, result) == :recoverable
    :ok = Failure.remember(context.binding, result, :degraded, :unsupported)
    assert Failure.class(context.binding, result) == :degraded
    assert Failure.reason_tag(context.binding, result) == :unsupported
    restart_store(context.store)
    assert Failure.class(context.binding, result) == :degraded
  end

  test "owned media reference indexes stay on disk and retain the original resource", context do
    alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Runtime.ensure_binding(context.runtime, MockAdapter, "media", transport: transport)
    opts = [binding: binding, request_id: "media-once"]
    payload = %{kind: :image, data: "complete"}
    assert {:ok, original} = Jido.Messaging.AdapterBridge.send_media(MockAdapter, "room", payload, opts)
    rows = :ets.tab2list(binding.resources) |> Enum.sort()
    assert length(rows) == 2
    assert Enum.count(rows, &match?({{:resource, _}, _, _, _, _, _}, &1)) == 1

    for index <- 1..1_001 do
      assert {:ok, _} = Jido.Chat.execute(context.binding, request("evict-#{index}", "new"))
    end

    restart_store(context.store)
    assert {:ok, ^original} = Jido.Messaging.AdapterBridge.send_media(MockAdapter, "room", payload, opts)
    assert :ets.tab2list(binding.resources) |> Enum.sort() == rows
    assert [%{operation: :send_file}] = MockTransport.calls(transport)

    assert {:error, %Contract{code: :request_conflict}} =
             Jido.Messaging.AdapterBridge.send_media(MockAdapter, "room", %{payload | data: "changed"}, opts)
  end

  test "private provider boundary marks worker death unknown without stopping its owner", context do
    data = %{"room_id" => "room", "text" => "held"}

    assert {:invoke, invocation, completion} =
             ProviderCall.prepare_operation(Adapter, :send_message, data,
               binding: context.binding,
               request_id: "worker-death"
             )

    {worker, monitor} = spawn_monitor(fn -> ProviderCall.invoke_operation(invocation) end)
    assert_receive {:provider, ^worker, "held", _}, 1_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert {:error, %Contract{code: :request_outcome_unknown}} = ProviderCall.unknown_operation(completion)

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             ProviderCall.complete_operation(completion, {:ok, %{id: "late"}})

    restart_store(context.store)

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             ProviderCall.operation(Adapter, :send_message, data, binding: context.binding, request_id: "worker-death")

    assert Process.alive?(Process.whereis(context.runtime))
    assert {:ok, _} = Jido.Chat.execute(context.binding, request("next-job", "next"))
    assert_received {:provider, _, "next", _}
    refute_received {:provider, _, _, _}
  end

  test "private completion owns large result handles and ignores duplicate outcomes", context do
    text = String.duplicate("large", 60_000)
    data = %{"room_id" => "room", "text" => "large"}

    assert {:invoke, invocation, completion} =
             ProviderCall.prepare_operation(Adapter, :send_message, data,
               binding: context.binding,
               request_id: "large-boundary"
             )

    outcome = Task.async(fn -> ProviderCall.invoke_operation(invocation) end) |> Task.await()
    assert {:ok, result} = ProviderCall.complete_operation(completion, outcome)
    ref = result["resource_ref"]
    assert {:ok, value} = Resources.resolve(context.binding, ref)
    assert value["text"] == text
    before = :ets.tab2list(context.binding.resources) |> Enum.sort()
    assert {:ok, ^result} = ProviderCall.complete_operation(completion, {:error, :late})
    assert :ets.tab2list(context.binding.resources) |> Enum.sort() == before

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             Task.async(fn -> ProviderCall.complete_operation(completion, outcome) end) |> Task.await()

    assert {:ok, ^value} = Resources.resolve(context.binding, ref)
  end

  test "store replacement between invocation and completion leaves no projected resource", context do
    data = %{"room_id" => "room", "text" => "ready"}

    assert {:invoke, invocation, completion} =
             ProviderCall.prepare_operation(Adapter, :send_message, data,
               binding: context.binding,
               request_id: "store-loss"
             )

    outcome = Task.async(fn -> ProviderCall.invoke_operation(invocation) end) |> Task.await()
    restart_store(context.store)
    assert {:error, %Contract{code: :request_outcome_unknown}} = ProviderCall.complete_operation(completion, outcome)
    assert :ets.info(context.binding.resources, :size) == 1

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             ProviderCall.operation(Adapter, :send_message, data, binding: context.binding, request_id: "store-loss")
  end

  defp request(id, text), do: SendMessage.new!(%{"request_id" => id, "room_id" => "room", "text" => text})

  defp restart_store(store) do
    {:ok, stats} = RequestStore.call(store, :stats)
    Process.exit(stats.worker, :kill)
    wait_for_worker(store, stats.worker)
  end

  defp wait_for_worker(store, old) do
    assert_eventually(
      fn ->
        case RequestStore.call(store, :stats) do
          {:ok, %{worker: worker}} -> is_pid(worker) and worker != old
          _ -> false
        end
      end,
      timeout: 2_000
    )
  end

  defp drain_calls(acc \\ []) do
    receive do
      {:provider, _, _, _} = call -> drain_calls([call | acc])
    after
      0 -> acc
    end
  end
end
