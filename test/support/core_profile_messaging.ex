defmodule Jido.Messaging.CoreProfileMessaging do
  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.ETS,
    runtime_profile: :core
end
