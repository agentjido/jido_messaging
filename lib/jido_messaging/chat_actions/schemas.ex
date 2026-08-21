defmodule Jido.Messaging.ChatActions.TargetSchema do
  @moduledoc false

  @doc false
  @spec schema() :: Zoi.schema()
  def schema do
    Zoi.object(%{
      kind: Zoi.union([Zoi.atom(), Zoi.string()]) |> Zoi.optional(),
      external_id: Zoi.string(description: "Provider channel or room identifier"),
      thread_id: Zoi.string(description: "Provider thread identifier") |> Zoi.nullish(),
      reply_to_mode: Zoi.union([Zoi.atom(), Zoi.string()]) |> Zoi.optional(),
      reply_to_id: Zoi.string(description: "Provider reply identifier") |> Zoi.nullish(),
      instance_id: Zoi.string(description: "Configured bridge identifier"),
      channel_type: Zoi.union([Zoi.atom(), Zoi.string()]) |> Zoi.nullish()
    })
  end
end

defmodule Jido.Messaging.ChatActions.ReaderSchema do
  @moduledoc false

  @doc false
  @spec target() :: Zoi.schema()
  def target do
    Zoi.object(%{target: Jido.Messaging.ChatActions.TargetSchema.schema()})
  end

  @doc false
  @spec page() :: Zoi.schema()
  def page do
    Zoi.object(%{
      target: Jido.Messaging.ChatActions.TargetSchema.schema(),
      cursor: Zoi.string(description: "Page cursor") |> Zoi.optional(),
      limit: Zoi.integer(description: "Maximum items") |> Zoi.min(1) |> Zoi.max(200) |> Zoi.optional(),
      direction: Zoi.enum([:forward, :backward]) |> Zoi.optional()
    })
  end

  @doc false
  @spec lookup() :: Zoi.schema()
  def lookup do
    Zoi.object(%{
      target: Jido.Messaging.ChatActions.TargetSchema.schema(),
      query: Zoi.map(description: "Normalized directory query")
    })
  end
end

defmodule Jido.Messaging.ChatActions.MessengerSchema do
  @moduledoc false

  @doc false
  @spec text() :: Zoi.schema()
  def text do
    Zoi.object(%{
      target: Jido.Messaging.ChatActions.TargetSchema.schema(),
      text: Zoi.string(description: "Message text")
    })
  end
end

defmodule Jido.Messaging.ChatActions.ModeratorSchema do
  @moduledoc false

  @doc false
  @spec message() :: Zoi.schema()
  def message do
    Zoi.object(%{
      target: Jido.Messaging.ChatActions.TargetSchema.schema(),
      message_id: Zoi.string(description: "Provider message identifier")
    })
  end

  @doc false
  @spec message_text() :: Zoi.schema()
  def message_text do
    Zoi.object(%{
      target: Jido.Messaging.ChatActions.TargetSchema.schema(),
      message_id: Zoi.string(description: "Provider message identifier"),
      text: Zoi.string(description: "Replacement message text")
    })
  end

  @doc false
  @spec reaction() :: Zoi.schema()
  def reaction do
    Zoi.object(%{
      target: Jido.Messaging.ChatActions.TargetSchema.schema(),
      message_id: Zoi.string(description: "Provider message identifier"),
      emoji: Zoi.string(description: "Reaction emoji")
    })
  end
end
