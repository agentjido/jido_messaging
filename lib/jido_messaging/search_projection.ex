defmodule Jido.Messaging.SearchProjection do
  @moduledoc """
  Optional search projection contract for canonical transcript entries.

  Canonical persistence remains the source of truth. A projection consumes
  committed entries and can be rebuilt from `participant_transcript/3`. Search
  implementations must apply the supplied `HistoryScope` and instance module.

  The messaging core calls `search/3` and `rebuild/3`. Applications use
  `upsert_transcript_search/3` and `delete_transcript_search/4` from a committed
  message event consumer when they need incremental indexing. These helpers
  invoke `upsert/3` and `delete/3` after scope checks. Projection failure does
  not roll back canonical persistence.
  """

  alias Jido.Messaging.{HistoryScope, TranscriptEntry}

  @type context :: %{
          required(:instance_module) => module(),
          required(:scope) => HistoryScope.t()
        }

  @callback upsert(TranscriptEntry.t(), context(), keyword()) :: :ok | {:error, term()}
  @callback delete(String.t(), context(), keyword()) :: :ok | {:error, term()}
  @callback search(String.t(), context(), keyword()) ::
              {:ok, [TranscriptEntry.t()]} | {:error, term()}
  @callback rebuild([TranscriptEntry.t()], context(), keyword()) :: :ok | {:error, term()}
end
