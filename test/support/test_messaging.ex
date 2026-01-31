defmodule JidoMessaging.TestMessaging do
  @moduledoc "Test messaging module for use in tests"
  use JidoMessaging, adapter: JidoMessaging.Adapters.ETS
end
