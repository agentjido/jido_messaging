defmodule Jido.Messaging.TestMessaging do
  @moduledoc "Test messaging module for use in tests"
  use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
end
