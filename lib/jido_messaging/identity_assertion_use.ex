defmodule Jido.Messaging.IdentityAssertionUse do
  @moduledoc false

  @enforce_keys [:id, :credential_id, :assertion_key, :expires_at, :inserted_at]
  defstruct [:id, :credential_id, :assertion_key, :expires_at, :inserted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          credential_id: String.t(),
          assertion_key: String.t(),
          expires_at: DateTime.t(),
          inserted_at: DateTime.t()
        }

  @doc false
  @spec new(String.t(), String.t(), DateTime.t()) :: t()
  def new(credential_id, assertion_key, expires_at) do
    %__MODULE__{
      id: assertion_key,
      credential_id: credential_id,
      assertion_key: assertion_key,
      expires_at: expires_at,
      inserted_at: DateTime.utc_now()
    }
  end
end
