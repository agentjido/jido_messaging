defmodule Jido.Messaging.ProviderCallBoundaryTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{Diagnostics, ProviderCall}

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
    @impl true
    def send_message(room, text, opts) do
      send(opts[:probe], {:provider_call, self(), room, text})
      if text == "private-failure", do: {:error, {:network_error, "private-cause"}}, else: {:ok, %{id: "sent"}}
    end
  end

  defmodule LegacyChannel do
    def send_message(room, content, opts), do: {:sent, room, content, opts}
    def edit_message(room, message, content), do: {:edited, room, message, content}
  end

  setup do
    owner = self()
    handler = "provider-boundary-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:jido_messaging, :provider_call, :stop], [:jido_messaging, :execution, :failure]],
      fn event, measurements, metadata, pid -> send(pid, {:diagnostic, event, measurements, metadata}) end,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "boundary", probe: owner)
    %{binding: binding}
  end

  test "typed calls run in the caller and preserve Chat results and deduplication", %{binding: binding} do
    {:ok, request} =
      Jido.Chat.Signal.SendMessage.new(%{"request_id" => "one", "room_id" => "room", "text" => "private-content"})

    assert {:ok, result} = ProviderCall.execute(binding, request)
    assert result.type == "jido.chat.operation.completed"
    assert_receive {:provider_call, caller, "room", "private-content"}
    assert caller == self()
    assert_receive {:diagnostic, [:jido_messaging, :provider_call, :stop], %{duration: duration}, metadata}
    assert duration >= 0

    assert metadata == %{
             stage: :provider,
             operation: :send_message,
             outcome: :completed,
             failure_class: nil,
             signal_id: request.id,
             request_id: "one"
           }

    assert {:ok, ^result} = ProviderCall.execute(binding, request)
    refute_receive {:provider_call, _, _, _}
  end

  test "failure diagnostics have public correlation and class, without private causes", %{binding: binding} do
    {:ok, request} =
      Jido.Chat.Signal.SendMessage.new(%{"request_id" => "failure", "room_id" => "room", "text" => "private-failure"})

    assert {:ok, %{data: %{"code" => "provider_failure", "retryable" => true}}} = ProviderCall.execute(binding, request)
    assert_receive {:diagnostic, [:jido_messaging, :provider_call, :stop], _, metadata}
    assert metadata.outcome == :failed
    assert metadata.failure_class == :recoverable
    refute inspect(metadata) =~ "private"
    assert Map.keys(metadata) |> Enum.sort() == [:failure_class, :operation, :outcome, :request_id, :signal_id, :stage]
  end

  test "contract rejection does not invoke the provider", %{binding: binding} do
    {:ok, request} =
      Jido.Chat.Signal.SendMessage.new(%{"request_id" => "invalid", "room_id" => "room", "text" => "hello"})

    assert {:error, _} = ProviderCall.execute(%{binding | resources: :missing_table}, request)
    refute_receive {:provider_call, _, _, _}
    assert_receive {:diagnostic, [:jido_messaging, :provider_call, :stop], _, %{outcome: :contract_error}}

    assert {:error, _} = ProviderCall.execute(binding, %{request | type: "unknown.command"})
    refute_receive {:provider_call, _, _, _}

    assert_receive {:diagnostic, [:jido_messaging, :provider_call, :stop], _,
                    %{outcome: :contract_error, operation: :unknown}}
  end

  test "execution diagnostics omit malformed correlation fields" do
    Diagnostics.failure(:execution, struct(Jido.Signal, data: %{"request_id" => %{secret: "private"}}), :exit)

    assert_receive {:diagnostic, [:jido_messaging, :execution, :failure], %{count: 1},
                    %{stage: :execution, failure_class: :exit} = metadata}

    assert map_size(metadata) == 2
  end

  test "legacy Streaming callbacks preserve arities and raw return values" do
    assert {:sent, "room", "content", [token: :private]} =
             ProviderCall.legacy_send(LegacyChannel, "room", "content", token: :private)

    assert {:edited, "room", "message", "content"} =
             ProviderCall.legacy_edit(LegacyChannel, "room", "message", "content")
  end
end
