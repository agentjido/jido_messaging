defmodule Jido.Messaging.CommandResult do
  @moduledoc """
  Result returned by eventful `Jido.Messaging` command APIs.

  Low-level persistence functions return records directly. Command APIs return
  the committed record plus the `Jido.Signal` events emitted for that command so
  apps can test, inspect, or bridge realtime UI behavior without scraping logs.
  """

  @enforce_keys [:record]
  defstruct [:record, signals: [], metadata: %{}]

  @type t(record) :: %__MODULE__{
          record: record,
          signals: [Jido.Signal.t()],
          metadata: map()
        }

  @type t :: t(term())

  @doc """
  Builds a command result from the committed record and emitted signals.
  """
  @spec new(term(), [Jido.Signal.t()], map()) :: t()
  def new(record, signals \\ [], metadata \\ %{}) when is_list(signals) and is_map(metadata) do
    %__MODULE__{record: record, signals: signals, metadata: metadata}
  end
end
