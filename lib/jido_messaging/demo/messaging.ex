defmodule JidoMessaging.Demo.Messaging do
  @moduledoc """
  Demo messaging instance for the echo bot demo.
  """
  use JidoMessaging, adapter: JidoMessaging.Adapters.ETS
end
