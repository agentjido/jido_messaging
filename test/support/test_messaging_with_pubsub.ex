defmodule Jido.Messaging.TestMessagingWithPubSub do
  @moduledoc "Test messaging module with PubSub configured"
  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.ETS,
    pubsub: Jido.Messaging.TestPubSub
end
