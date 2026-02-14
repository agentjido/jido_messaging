defmodule JidoMessaging.ChannelTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channel

  defmodule LegacyChannel do
    @behaviour Channel

    @impl true
    def channel_type, do: :legacy

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

  defmodule V2AlignedChannel do
    @behaviour Channel

    @impl true
    def channel_type, do: :v2_aligned

    @impl true
    def capabilities, do: [:text, :command_hints]

    @impl true
    def transform_incoming(_payload) do
      {:ok,
       %{
         external_room_id: "room_2",
         external_user_id: "user_2",
         text: "hello"
       }}
    end

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "sent"}}

    @impl true
    def extract_command_hint(_incoming), do: {:ok, %{name: "ping"}}
  end

  defmodule MismatchedCapabilityChannel do
    @behaviour Channel

    @impl true
    def channel_type, do: :mismatch

    @impl true
    def capabilities, do: [:text, :command_hints]

    @impl true
    def transform_incoming(_payload) do
      {:ok,
       %{
         external_room_id: "room_3",
         external_user_id: "user_3",
         text: "hello"
       }}
    end

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "sent"}}
  end

  defmodule UnknownCapabilityChannel do
    @behaviour Channel

    @impl true
    def channel_type, do: :unknown_capability

    @impl true
    def capabilities, do: [:text, :unsupported_custom_capability]

    @impl true
    def transform_incoming(_payload) do
      {:ok,
       %{
         external_room_id: "room_4",
         external_user_id: "user_4",
         text: "hello"
       }}
    end

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "sent"}}
  end

  defmodule RecoverableFailureChannel do
    @behaviour Channel

    @impl true
    def channel_type, do: :recoverable_failure

    @impl true
    def capabilities, do: [:text, :sender_verification]

    @impl true
    def transform_incoming(_payload) do
      {:ok,
       %{
         external_room_id: "room_5",
         external_user_id: "user_5",
         text: "hello"
       }}
    end

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "sent"}}

    @impl true
    def verify_sender(_incoming, _raw_payload), do: {:error, :timeout}
  end

  defmodule FatalFailureChannel do
    @behaviour Channel

    @impl true
    def channel_type, do: :fatal_failure

    @impl true
    def capabilities, do: [:text, :outbound_sanitization]

    @impl true
    def transform_incoming(_payload) do
      {:ok,
       %{
         external_room_id: "room_6",
         external_user_id: "user_6",
         text: "hello"
       }}
    end

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "sent"}}

    @impl true
    def sanitize_outbound(_outbound, _opts), do: raise("broken sanitizer")
  end

  describe "v1 compatibility" do
    test "required callbacks still work for v1-only channels" do
      assert LegacyChannel.channel_type() == :legacy

      {:ok, incoming} = LegacyChannel.transform_incoming(%{text: "Hello"})
      assert incoming.external_room_id == "room_1"
      assert incoming.external_user_id == "user_1"
      assert incoming.text == "Hello"

      {:ok, result} = LegacyChannel.send_message("123", "Hi!", [])
      assert result.message_id == "msg_123_3"
    end

    test "v2 optional callbacks default deterministically for v1-only channels" do
      incoming = %{external_room_id: "room_1", external_user_id: "user_1", text: "hello"}

      assert {:ok, []} = Channel.listener_child_specs(LegacyChannel, "instance_1")
      assert {:ok, %{}} = Channel.extract_routing_metadata(LegacyChannel, %{"message" => "payload"})
      assert :ok = Channel.verify_sender(LegacyChannel, incoming, %{"raw" => "payload"})
      assert {:ok, "hello"} = Channel.sanitize_outbound(LegacyChannel, "hello")
      assert {:ok, nil} = Channel.extract_command_hint(LegacyChannel, incoming)

      assert {:error, send_media_failure} = Channel.send_media(LegacyChannel, "room_1", %{kind: :image})
      assert send_media_failure.type == :channel_callback_failure
      assert send_media_failure.callback == :send_media
      assert send_media_failure.class == :degraded
      assert send_media_failure.disposition == :degrade

      assert {:error, edit_media_failure} =
               Channel.edit_media(LegacyChannel, "room_1", "message_1", %{kind: :image})

      assert edit_media_failure.type == :channel_callback_failure
      assert edit_media_failure.callback == :edit_media
      assert edit_media_failure.class == :degraded

      assert {:error, edit_message_failure} =
               Channel.edit_message(LegacyChannel, "room_1", "message_1", "updated")

      assert edit_message_failure.type == :channel_callback_failure
      assert edit_message_failure.callback == :edit_message
      assert edit_message_failure.class == :degraded
    end
  end

  describe "capability contract checks" do
    test "first-party channels pass capability contract validation" do
      channels = [
        JidoMessaging.Channels.Telegram,
        JidoMessaging.Channels.Discord,
        JidoMessaging.Channels.Slack,
        JidoMessaging.Channels.WhatsApp
      ]

      for channel <- channels do
        assert :ok = Channel.validate_capability_contract(channel)
      end
    end

    test "passes for aligned v2 capabilities and callbacks" do
      assert :ok = Channel.validate_capability_contract(V2AlignedChannel)
    end

    test "returns typed failure when capabilities advertise unsupported callback contracts" do
      assert {:error, [failure]} = Channel.validate_capability_contract(MismatchedCapabilityChannel)

      assert failure.type == :channel_contract_failure
      assert failure.channel == MismatchedCapabilityChannel
      assert failure.capability == :command_hints
      assert failure.callback == :extract_command_hint
      assert failure.class == :fatal
      assert failure.disposition == :crash
      assert failure.reason == :missing_callback
    end

    test "returns typed failure for unknown capability atoms" do
      assert {:error, [failure]} = Channel.validate_capability_contract(UnknownCapabilityChannel)

      assert failure.type == :channel_contract_failure
      assert failure.channel == UnknownCapabilityChannel
      assert failure.capability == :unsupported_custom_capability
      assert failure.callback == :capabilities
      assert failure.class == :fatal
      assert failure.disposition == :crash
      assert failure.reason == :unknown_capability
    end
  end

  describe "failure classification" do
    test "classifies timeout callback failures as recoverable with retry disposition" do
      incoming = %{external_room_id: "room_5", external_user_id: "user_5", text: "hello"}

      assert {:error, failure} =
               Channel.verify_sender(RecoverableFailureChannel, incoming, %{"raw" => "payload"})

      assert failure.type == :channel_callback_failure
      assert failure.callback == :verify_sender
      assert failure.class == :recoverable
      assert failure.disposition == :retry
      assert failure.reason == :timeout
      assert Channel.failure_disposition(failure) == :retry
    end

    test "classifies raised callback failures as fatal with crash disposition" do
      assert {:error, failure} = Channel.sanitize_outbound(FatalFailureChannel, "hello")

      assert failure.type == :channel_callback_failure
      assert failure.callback == :sanitize_outbound
      assert failure.class == :fatal
      assert failure.disposition == :crash
      assert match?({:exception, %RuntimeError{}}, failure.reason)
      assert failure.kind == :error
      assert is_list(failure.stacktrace)
      assert Channel.failure_disposition(failure) == :crash
    end
  end

  describe "compile-time contract check" do
    test "use JidoMessaging.Channel enforces capability/callback alignment" do
      module_name = Module.concat(__MODULE__, :CompileMismatch)

      code = """
      defmodule #{inspect(module_name)} do
        use JidoMessaging.Channel

        @impl true
        def channel_type, do: :compile_mismatch

        @impl true
        def capabilities, do: [:command_hints]

        @impl true
        def transform_incoming(_payload) do
          {:ok, %{external_room_id: \"room\", external_user_id: \"user\", text: \"hello\"}}
        end

        @impl true
        def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: \"sent\"}}
      end
      """

      assert_raise CompileError, ~r/channel capability contract failed/, fn ->
        Code.compile_string(code)
      end
    end
  end
end
