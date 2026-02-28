defmodule Jido.Messaging.TestMessaging do
  @moduledoc "Test messaging module for use in tests"
  use Jido.Messaging, adapter: Jido.Messaging.Adapters.ETS
end
