defmodule Jido.Messaging.RequestLedger do
  @moduledoc false

  # The Runtime process owns this table. Resource handles also use the table.
  # No timer, size eviction, or age expiry can release a request ID.
  alias Jido.Chat.Signal.Policy

  @type claim :: {term(), binary(), term()}

  @spec new() :: :ets.table()
  def new, do: :ets.new(:messaging_request_admissions, [:set, :public])

  @spec claim(:ets.table(), term(), term(), term()) ::
          {:ok, claim()} | {:cached, term()} | {:error, term()}
  def claim(table, key, payload, authority) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))

    if :ets.insert_new(table, {key, digest, authority, {:running, self()}}) do
      {:ok, {key, digest, authority}}
    else
      case :ets.lookup(table, key) do
        [{^key, ^digest, ^authority, {:done, result}}] ->
          {:cached, result}

        [{^key, ^digest, ^authority, {:running, owner}}] ->
          Policy.error(if(Process.alive?(owner), do: :request_in_progress, else: :request_outcome_unknown))

        _ ->
          Policy.error(:request_conflict)
      end
    end
  end

  @spec complete(:ets.table(), claim(), term()) :: :ok
  def complete(table, {key, digest, authority}, result) do
    :ets.insert(table, {key, digest, authority, {:done, result}})
    :ok
  end
end
