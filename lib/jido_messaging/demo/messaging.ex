defmodule Jido.Messaging.Demo.Messaging do
  @moduledoc """
  Demo messaging instance for the echo bot demo.
  """
  use Jido.Messaging, adapter: Jido.Messaging.Adapters.ETS
end
