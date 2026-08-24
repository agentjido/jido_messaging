defmodule Jido.Messaging.IdentityProvider do
  @moduledoc """
  Optional proof-verification callback implemented outside messaging core.

  The provider can use cryptography, a remote identity service, or another
  host-owned verifier. It must not return private keys, tokens, or raw proofs.
  """

  alias Jido.Messaging.IdentityCredential

  @type result ::
          {:ok,
           %{
             required(:assurance) => :attested | :verified,
             optional(:key_version_ref) => String.t(),
             optional(:metadata) => map()
           }}
          | {:error, term()}

  @doc "Verifies one transient proof for the credential and exact context."
  @callback verify(IdentityCredential.t(), proof :: map(), context :: map(), opts :: keyword()) ::
              result()
end
