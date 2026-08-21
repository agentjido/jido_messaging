defmodule Jido.Messaging.ChatActions.Moderator.EditMessage do
  @moduledoc "Edits a message after policy approval."
  use Jido.Messaging.ChatActions.Action,
    operation: :edit_message,
    name: "chat_edit_message",
    description: "Edit a message in the authorized chat target.",
    schema: Jido.Messaging.ChatActions.ModeratorSchema.message_text()
end

defmodule Jido.Messaging.ChatActions.Moderator.DeleteMessage do
  @moduledoc "Deletes a message after policy approval."
  use Jido.Messaging.ChatActions.Action,
    operation: :delete_message,
    name: "chat_delete_message",
    description: "Delete a message in the authorized chat target.",
    schema: Jido.Messaging.ChatActions.ModeratorSchema.message()
end

defmodule Jido.Messaging.ChatActions.Moderator.AddReaction do
  @moduledoc "Adds a reaction after policy approval."
  use Jido.Messaging.ChatActions.Action,
    operation: :add_reaction,
    name: "chat_add_reaction",
    description: "Add a reaction to a message in the authorized chat target.",
    schema: Jido.Messaging.ChatActions.ModeratorSchema.reaction()
end

defmodule Jido.Messaging.ChatActions.Moderator.RemoveReaction do
  @moduledoc "Removes a reaction after policy approval."
  use Jido.Messaging.ChatActions.Action,
    operation: :remove_reaction,
    name: "chat_remove_reaction",
    description: "Remove a reaction from a message in the authorized chat target.",
    schema: Jido.Messaging.ChatActions.ModeratorSchema.reaction()
end

defmodule Jido.Messaging.ChatActions.Moderator.EnsureSubscription do
  @moduledoc "Ensures a provider subscription after policy approval."
  use Jido.Messaging.ChatActions.Action,
    operation: :ensure_subscription,
    name: "chat_ensure_subscription",
    description: "Ensure a provider subscription under explicit workspace authority.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.target()
end

defmodule Jido.Messaging.ChatActions.Moderator.ListSubscriptions do
  @moduledoc "Lists provider subscriptions under explicit workspace authority."
  use Jido.Messaging.ChatActions.Action,
    operation: :list_subscriptions,
    name: "chat_list_subscriptions",
    description: "List provider subscriptions under explicit workspace authority.",
    schema: Jido.Messaging.ChatActions.ReaderSchema.target()
end

defmodule Jido.Messaging.ChatActions.Moderator.DeleteSubscription do
  @moduledoc "Deletes a provider subscription after policy approval."
  use Jido.Messaging.ChatActions.Action,
    operation: :delete_subscription,
    name: "chat_delete_subscription",
    description: "Delete a provider subscription under explicit workspace authority.",
    schema:
      Zoi.object(%{
        target: Jido.Messaging.ChatActions.TargetSchema.schema(),
        subscription_id: Zoi.string(description: "Provider subscription identifier")
      })
end
