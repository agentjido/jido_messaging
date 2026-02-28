defmodule Jido.Messaging.TestMessagingWithPubSub do
  @moduledoc "Test messaging module with PubSub configured"
  use Jido.Messaging,
    adapter: Jido.Messaging.Adapters.ETS,
    pubsub: Jido.Messaging.TestPubSub
end
