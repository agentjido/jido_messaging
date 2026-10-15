defmodule Jido.Messaging.RequestLedger do
  @moduledoc false

  # Runtime owns the resource table. The single private locator is independent
  # of request count; request history and all indexes stay in the disk store.
  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.RequestStore

  @type claim :: {term(), binary(), term()}

  @spec new() :: :ets.table()
  def new do
    table = :ets.new(:messaging_request_admissions, [:set, :public])
    {:ok, store} = RequestStore.start_link(self())
    :ets.insert(table, {RequestStore, store})
    table
  end

  @spec claim(:ets.table(), term(), term(), term()) ::
          {:ok, claim()} | {:cached, term()} | {:error, term()}
  def claim(table, key, payload, authority) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))

    with {:ok, store} <- store(table), do: RequestStore.call(store, {:claim, key, digest, authority})
  end

  @spec complete(:ets.table(), claim(), term()) :: :ok | {:error, term()}
  def complete(table, claim, result) do
    with {:ok, store} <- store(table), do: RequestStore.call(store, {:complete, claim, result})
  end

  defp store(table) do
    case :ets.lookup(table, RequestStore) do
      [{RequestStore, store}] -> {:ok, store}
      _ -> Policy.error(:request_outcome_unknown)
    end
  rescue
    ArgumentError -> Policy.error(:request_outcome_unknown)
  end
end
