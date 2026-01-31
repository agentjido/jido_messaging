defmodule JidoMessaging.Channels.Telegram.HandlerTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channels.Telegram.Handler

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  defmodule MockChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(%{message: nil}), do: {:error, :no_message}

    def transform_incoming(%{message: msg}) do
      {:ok,
       %{
         external_room_id: msg.chat.id,
         external_user_id: msg.from.id,
         text: msg.text,
         username: msg.from.username,
         display_name: msg.from.first_name
       }}
    end

    @impl true
    def send_message(_chat_id, text, _opts) do
      if text == "fail" do
        {:error, :send_failed}
      else
        {:ok, %{message_id: 999}}
      end
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "process_update/4" do
    test "processes valid update without callback" do
      update = build_update("Hello!")

      result = Handler.process_update(update, TestMessaging, "test_inst", nil)
      assert result == :ok
    end

    test "processes valid update with echo callback" do
      update = build_update("Echo me")

      callback = fn message, _context ->
        {:reply, "Echo: #{hd(message.content).text}"}
      end

      result = Handler.process_update(update, TestMessaging, "echo_inst", callback)
      assert result == :ok
    end

    test "processes update with noreply callback" do
      update = build_update("Ignored")

      callback = fn _message, _context ->
        :noreply
      end

      result = Handler.process_update(update, TestMessaging, "noreply_inst", callback)
      assert result == :ok
    end

    test "handles callback error" do
      update = build_update("Error trigger")

      callback = fn _message, _context ->
        {:error, :handler_failed}
      end

      result = Handler.process_update(update, TestMessaging, "error_inst", callback)
      assert result == :ok
    end

    test "handles unexpected callback result" do
      update = build_update("Unexpected")

      callback = fn _message, _context ->
        :unexpected_atom
      end

      result = Handler.process_update(update, TestMessaging, "unexpected_inst", callback)
      assert result == :ok
    end

    test "skips updates without message" do
      update = %{message: nil}

      result = Handler.process_update(update, TestMessaging, "skip_inst", nil)
      assert result == :ok
    end
  end

  defp build_update(text) do
    %{
      message: %{
        message_id: :rand.uniform(10000),
        date: System.system_time(:second),
        chat: %{
          id: :rand.uniform(10000),
          type: "private"
        },
        from: %{
          id: :rand.uniform(10000),
          first_name: "Test",
          username: "testuser"
        },
        text: text
      }
    }
  end
end
