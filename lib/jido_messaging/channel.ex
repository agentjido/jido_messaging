defmodule JidoMessaging.Channel do
  @moduledoc """
  Behaviour for messaging channel implementations.

  Channels handle communication with external platforms (Telegram, Discord, etc.)
  and transform platform-specific messages to/from normalized JidoMessaging structs.

  ## Implementing a Channel

      defmodule MyApp.Channels.CustomChannel do
        @behaviour JidoMessaging.Channel

        @impl true
        def channel_type, do: :custom

        @impl true
        def transform_incoming(raw_payload) do
          # Parse platform-specific payload into normalized struct
          {:ok, %{external_room_id: "...", external_user_id: "...", text: "..."}}
        end

        @impl true
        def send_message(external_room_id, text, opts) do
          # Send message to platform
          {:ok, %{message_id: "..."}}
        end
      end
  """

  @type raw_payload :: map()
  @type external_room_id :: String.t() | integer()
  @type external_user_id :: String.t() | integer()
  @type external_message_id :: String.t() | integer()

  @type incoming_message :: %{
          required(:external_room_id) => external_room_id(),
          required(:external_user_id) => external_user_id(),
          required(:text) => String.t() | nil,
          optional(:username) => String.t() | nil,
          optional(:display_name) => String.t() | nil,
          optional(:external_message_id) => external_message_id(),
          optional(:external_reply_to_id) => external_message_id() | nil,
          optional(:external_thread_id) => String.t() | nil,
          optional(:timestamp) => integer() | nil,
          optional(:chat_type) => atom(),
          optional(:chat_title) => String.t() | nil,
          optional(:was_mentioned) => boolean(),
          optional(:mentions) => [map()],
          optional(:channel_meta) => map(),
          optional(:raw) => map()
        }

  @type send_result :: {:ok, map()} | {:error, term()}

  @type capability ::
          :text | :image | :audio | :video | :file | :tool_use | :streaming | :reactions | :threads

  @doc "Returns the channel type atom (e.g., :telegram, :discord)"
  @callback channel_type() :: atom()

  @doc """
  Returns the list of capabilities this channel supports.

  Defaults to `[:text]` if not implemented.
  """
  @callback capabilities() :: [capability()]

  @optional_callbacks capabilities: 0

  @doc """
  Transform a raw incoming payload into a normalized message struct.

  Returns `{:ok, incoming_message}` or `{:error, reason}` if the payload
  cannot be parsed (e.g., not a message update).
  """
  @callback transform_incoming(raw_payload()) ::
              {:ok, incoming_message()} | {:error, term()}

  @doc """
  Send a text message to an external room.

  Options may include platform-specific settings like parse_mode, reply_to, etc.
  """
  @callback send_message(external_room_id(), text :: String.t(), opts :: keyword()) ::
              send_result()
end
