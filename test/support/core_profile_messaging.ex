defmodule Jido.Messaging.CoreProfileMessaging do
  @moduledoc """
  Test support instance configured with the core runtime profile.
  """

  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.ETS,
    runtime_profile: :core
end
