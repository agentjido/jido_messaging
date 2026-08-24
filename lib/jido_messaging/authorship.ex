defmodule Jido.Messaging.Authorship do
  @moduledoc """
  Immutable authorship assertion stored with a canonical message.

  Authorship identifies the canonical principal, the scoped provider binding,
  and the assurance that existed when the message was accepted. `proof_ref`
  must be an opaque reference. It must not contain a credential or raw proof.
  """

  alias Jido.Messaging.ExternalIdentityBinding

  @schema Zoi.struct(
            __MODULE__,
            %{
              principal_id: Zoi.string(),
              participant_id: Zoi.string(),
              external_identity_binding_id: Zoi.string() |> Zoi.nullish(),
              assurance:
                Zoi.enum([
                  :asserted,
                  :provider_verified,
                  :application_verified,
                  :cryptographically_verified
                ])
                |> Zoi.default(:asserted),
              proof_ref: Zoi.string() |> Zoi.nullish(),
              runtime_execution_id: Zoi.string() |> Zoi.nullish(),
              asserted_at: Zoi.struct(DateTime),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Authorship."
  def schema, do: @schema

  @doc "Creates an authorship assertion."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:asserted_at, DateTime.utc_now())
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Creates authorship from a canonical participant and scoped binding."
  @spec from_binding(String.t(), ExternalIdentityBinding.t(), keyword()) :: t()
  def from_binding(participant_id, %ExternalIdentityBinding{} = binding, opts \\ []) do
    new(%{
      principal_id: binding.principal_id,
      participant_id: participant_id,
      external_identity_binding_id: binding.id,
      assurance: Keyword.get(opts, :assurance, binding.assurance),
      proof_ref: Keyword.get(opts, :proof_ref, binding.proof_ref),
      runtime_execution_id: Keyword.get(opts, :runtime_execution_id),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @doc "Creates compatibility authorship for a message without a typed binding."
  @spec asserted(String.t(), DateTime.t() | nil) :: t()
  def asserted(participant_id, asserted_at \\ nil) when is_binary(participant_id) do
    new(%{
      principal_id: participant_id,
      participant_id: participant_id,
      assurance: :asserted,
      asserted_at: asserted_at || DateTime.utc_now()
    })
  end

  @doc "Converts authorship to the plain map stored in message metadata."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = authorship), do: Map.from_struct(authorship)

  @doc "Parses authorship from a struct or metadata map."
  @spec from_map(t() | map()) :: {:ok, t()} | {:error, :invalid_authorship}
  def from_map(%__MODULE__{} = authorship), do: {:ok, authorship}

  def from_map(map) when is_map(map) do
    attrs =
      Enum.reduce(
        [
          :principal_id,
          :participant_id,
          :external_identity_binding_id,
          :assurance,
          :proof_ref,
          :runtime_execution_id,
          :asserted_at,
          :metadata
        ],
        %{},
        fn key, result ->
          case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
            nil -> result
            value -> Map.put(result, key, value)
          end
        end
      )

    {:ok, new(attrs)}
  rescue
    _exception -> {:error, :invalid_authorship}
  end

  def from_map(_other), do: {:error, :invalid_authorship}
end
