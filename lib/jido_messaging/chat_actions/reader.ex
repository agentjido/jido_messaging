defmodule Jido.Messaging.ChatActions.Reader.FetchMessage do
  @moduledoc "Fetches one normalized message in the authorized conversation."
  use Jido.Messaging.ChatActions.Action,
    operation: :fetch_message,
    name: "chat_fetch_message",
    description: "Fetch one message from the authorized chat target.",
    schema:
      Zoi.object(%{
        target: Jido.Messaging.ChatActions.TargetSchema.schema(),
        message_id: Zoi.string(description: "Provider message identifier")
      })
end

defmodule Jido.Messaging.ChatActions.Reader.FetchChannelMessages do
  @moduledoc "Fetches a normalized page of channel messages."
  use Jido.Messaging.ChatActions.Action,
    operation: :fetch_channel_messages,
    name: "chat_fetch_channel_messages",
    description: "Fetch messages from the authorized channel.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.page()
end

defmodule Jido.Messaging.ChatActions.Reader.FetchThread do
  @moduledoc "Fetches normalized thread metadata."
  use Jido.Messaging.ChatActions.Action,
    operation: :fetch_thread,
    name: "chat_fetch_thread",
    description: "Fetch metadata for the authorized thread.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.target()
end

defmodule Jido.Messaging.ChatActions.Reader.FetchThreadMessages do
  @moduledoc "Fetches a normalized page of thread messages."
  use Jido.Messaging.ChatActions.Action,
    operation: :fetch_thread_messages,
    name: "chat_fetch_thread_messages",
    description: "Fetch messages from the authorized thread.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.page()
end

defmodule Jido.Messaging.ChatActions.Reader.ListThreads do
  @moduledoc "Lists normalized thread summaries in an authorized channel."
  use Jido.Messaging.ChatActions.Action,
    operation: :list_threads,
    name: "chat_list_threads",
    description: "List threads in the authorized channel.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.page()
end

defmodule Jido.Messaging.ChatActions.Reader.LookupParticipant do
  @moduledoc "Looks up a participant through the runtime directory."
  use Jido.Messaging.ChatActions.Action,
    operation: :lookup_participant,
    name: "chat_lookup_participant",
    description: "Look up one participant in the authorized adapter directory.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.lookup()
end

defmodule Jido.Messaging.ChatActions.Reader.LookupUser do
  @moduledoc "Looks up a provider user through an available directory seam."
  use Jido.Messaging.ChatActions.Action,
    operation: :lookup_user,
    name: "chat_lookup_user",
    description: "Look up one user in the authorized adapter directory.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.lookup()
end

defmodule Jido.Messaging.ChatActions.Reader.FetchChannelMetadata do
  @moduledoc "Fetches normalized channel metadata."
  use Jido.Messaging.ChatActions.Action,
    operation: :fetch_channel_metadata,
    name: "chat_fetch_channel_metadata",
    description: "Fetch metadata for the authorized channel.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.target()
end
