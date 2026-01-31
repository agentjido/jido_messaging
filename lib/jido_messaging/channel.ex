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
          optional(:timestamp) => integer() | nil,
          optional(:chat_type) => atom(),
          optional(:chat_title) => String.t() | nil
        }

  @type send_result :: {:ok, map()} | {:error, term()}

  @doc "Returns the channel type atom (e.g., :telegram, :discord)"
  @callback channel_type() :: atom()

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
