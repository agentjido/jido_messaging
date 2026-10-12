defmodule Jido.Messaging.AdapterBridgeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Capabilities
  alias Jido.Messaging.AdapterBridge

  defmodule MatrixAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :matrix

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "matrix-1"}}

    @impl true
    def send_file(_room, _file, _opts), do: {:ok, %{id: "file"}}
    @impl true
    def post_ephemeral(_room, _user, _text, _opts), do: {:ok, %{id: "ephemeral"}}
    @impl true
    def open_thread(_room, _message, _opts), do: {:ok, %{id: "thread"}}
    @impl true
    def open_modal(_room, _modal, _opts), do: {:ok, %{opened: true}}
    @impl true
    def add_reaction(_room, _message, _reaction, _opts), do: :ok

    @impl true
    def capabilities do
      %{
        send_message: :native,
        send_file: :native,
        markdown: :native,
        post_ephemeral: :native,
        open_thread: :native,
        open_modal: :native,
        add_reaction: :native,
        stream: :fallback
      }
    end

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _payload), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  defmodule LegacyListAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :legacy

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "legacy-1"}}

    @impl true
    def capabilities, do: [:image, :threads, :custom_capability]

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _payload), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  defmodule NoCapabilitiesAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :minimal

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "minimal-1"}}

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _payload), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  test "capabilities/1 reuses the core channel capability model for capability matrices" do
    assert AdapterBridge.capabilities(MatrixAdapter) ==
             Capabilities.channel_capabilities(MatrixAdapter)
  end

  test "capabilities/1 preserves legacy list-based capability declarations" do
    assert AdapterBridge.capabilities(LegacyListAdapter) == [:text, :image, :threads, :custom_capability]
  end

  test "capabilities/1 uses core fallbacks when no capability declaration exists" do
    assert AdapterBridge.capabilities(NoCapabilitiesAdapter) == [:text, :streaming]
    assert {:ok, binding} = Jido.Chat.bind(NoCapabilitiesAdapter, id: "minimal")

    assert {:ok, result} =
             Jido.Chat.execute(
               binding,
               Jido.Chat.Signal.PostMessage.new!(%{
                 "request_id" => "post",
                 "room_id" => "room",
                 "content" => %{"kind" => "text", "text" => "hello"}
               })
             )

    assert result.type == "jido.chat.operation.completed"
  end
end
