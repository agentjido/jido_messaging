defmodule JidoMessaging.ChannelTest do
  use ExUnit.Case, async: true

  describe "Channel behaviour" do
    defmodule TestChannel do
      @behaviour JidoMessaging.Channel

      @impl true
      def channel_type, do: :test

      @impl true
      def transform_incoming(%{text: text}) do
        {:ok,
         %{
           external_room_id: "room_1",
           external_user_id: "user_1",
           text: text
         }}
      end

      @impl true
      def send_message(chat_id, text, _opts) do
        {:ok, %{message_id: "msg_#{chat_id}_#{String.length(text)}"}}
      end
    end

    test "channel_type returns atom" do
      assert TestChannel.channel_type() == :test
    end

    test "transform_incoming returns normalized struct" do
      {:ok, incoming} = TestChannel.transform_incoming(%{text: "Hello"})
      assert incoming.external_room_id == "room_1"
      assert incoming.external_user_id == "user_1"
      assert incoming.text == "Hello"
    end

    test "send_message returns message info" do
      {:ok, result} = TestChannel.send_message("123", "Hi!", [])
      assert result.message_id == "msg_123_3"
    end
  end
end
