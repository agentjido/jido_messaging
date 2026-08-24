defmodule Jido.Messaging.TrustEvidenceProvider do
  @moduledoc """
  Provider contract for scoped advisory trust evidence.

  A provider returns allow-listed `TrustEvidence` records for the exact scope.
  It must not return a score, rank, recommendation, agent process, grant, or
  credential. Jido Messaging validates the records and converts provider
  failure into an explicit unavailable result.
  """

  alias Jido.Messaging.{TrustEvidence, TrustEvidenceScope}

  @doc "Returns a stable public provider identifier."
  @callback id() :: String.t()

  @doc "Returns evidence for the exact subject and room in the supplied scope."
  @callback query(TrustEvidenceScope.t(), keyword()) ::
              {:ok, [TrustEvidence.t()]} | {:error, term()}
end
