defmodule Jido.Messaging.Persistence.Contracts.Transactions do
  @moduledoc """
  Storage contract for transactions and connection release.

  These callbacks are required for adapters that declare this behaviour.
  ETS does not claim this group. See `docs/storage-contracts.md`.
  """

  @type state :: Jido.Messaging.Persistence.state()
  @type transaction_result(value) :: Jido.Messaging.Persistence.transaction_result(value)

  @callback transaction(state, (state -> transaction_result(value))) :: transaction_result(value)
            when value: term()

  @callback close(state) :: :ok
end
