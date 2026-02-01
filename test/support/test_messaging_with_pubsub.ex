defmodule JidoMessaging.TestMessagingWithPubSub do
  @moduledoc "Test messaging module with PubSub configured"
  use JidoMessaging,
    adapter: JidoMessaging.Adapters.ETS,
    pubsub: JidoMessaging.TestPubSub
end
