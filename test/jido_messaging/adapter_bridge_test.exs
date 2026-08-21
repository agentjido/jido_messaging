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
    def capabilities do
      %{
        send_message: :native,
        send_file: :fallback,
        markdown: :native,
        post_ephemeral: :native,
        open_thread: :native,
        open_modal: :native,
        add_reaction: :native,
        stream: :fallback
      }
    end

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}
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
    def transform_incoming(_raw), do: {:error, :not_implemented}
  end

  defmodule NoCapabilitiesAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :minimal

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "minimal-1"}}

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}
  end

  test "capabilities/1 reuses the core channel capability model for capability matrices" do
    assert AdapterBridge.capabilities(MatrixAdapter) ==
             Capabilities.channel_capabilities(MatrixAdapter)
  end

  test "capabilities/1 preserves legacy list-based capability declarations" do
    assert AdapterBridge.capabilities(LegacyListAdapter) == [:text, :image, :threads, :custom_capability]
  end

  test "capabilities/1 uses core fallbacks when no capability declaration exists" do
    assert AdapterBridge.capabilities(NoCapabilitiesAdapter) == [
             :text,
             :streaming,
             :card_charts,
             :card_tables,
             :link_action_ids
           ]
  end
end
