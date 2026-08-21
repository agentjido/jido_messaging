defmodule Jido.Messaging.ChatActions.Messenger.PostMessage do
  @moduledoc "Posts a message in the authorized channel or thread."
  use Jido.Messaging.ChatActions.Action,
    operation: :post_message,
    name: "chat_post_message",
    description: "Post a message in the authorized chat target.",
    schema: Jido.Messaging.ChatActions.MessengerSchema.text()
end

defmodule Jido.Messaging.ChatActions.Messenger.PostChannelMessage do
  @moduledoc "Posts a channel-level message."
  use Jido.Messaging.ChatActions.Action,
    operation: :post_channel_message,
    name: "chat_post_channel_message",
    description: "Post a message at channel level.",
    schema: Jido.Messaging.ChatActions.MessengerSchema.text()
end

defmodule Jido.Messaging.ChatActions.Messenger.SendDirectMessage do
  @moduledoc "Opens a direct-message room and posts a message."
  use Jido.Messaging.ChatActions.Action,
    operation: :send_direct_message,
    name: "chat_send_direct_message",
    description: "Send a direct message under explicit workspace authority.",
    schema:
      Zoi.object(%{
        target: Jido.Messaging.ChatActions.TargetSchema.schema(),
        user_id: Zoi.string(description: "Provider user identifier"),
        text: Zoi.string(description: "Message text")
      })
end

defmodule Jido.Messaging.ChatActions.Messenger.StartTyping do
  @moduledoc "Starts a typing indicator for the authorized target."
  use Jido.Messaging.ChatActions.Action,
    operation: :start_typing,
    name: "chat_start_typing",
    description: "Start a typing indicator in the authorized chat target.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.target()
end
