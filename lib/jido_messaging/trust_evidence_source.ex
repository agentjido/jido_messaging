defmodule Jido.Messaging.TrustEvidenceSource do
  @moduledoc """
  Safe source identity for one advisory trust-evidence claim.

  A message source refers to a canonical Jido Messaging message. A provider
  record is an opaque identifier from a trusted host-selected provider. The
  source cannot contain message text, runtime output, or credentials. Jido
  Messaging does not resolve or fetch provider-record identifiers.
  """

  alias Jido.Messaging.TrustEvidenceData

  @kinds [:message, :provider_record]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum(@kinds),
              provider_id: Zoi.string(),
              id: Zoi.string(),
              revision: Zoi.integer()
            },
            coerce: true
          )

  @type kind :: :message | :provider_record
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [:kind, :provider_id, :id, :revision]

  @doc "Returns the Zoi schema for TrustEvidenceSource."
  def schema, do: @schema

  @doc "Builds a strict source identity."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = source), do: source |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = TrustEvidenceData.strict_keys!(attrs, @allowed_keys, "trust evidence source")
    kind = attrs |> TrustEvidenceData.value(:kind) |> TrustEvidenceData.enum!(@kinds, :evidence_source_kind)

    provider_id =
      attrs
      |> TrustEvidenceData.value(:provider_id, default_provider(kind))
      |> TrustEvidenceData.code!(:provider_id)

    :ok = validate_provider!(kind, provider_id)

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      kind: kind,
      provider_id: provider_id,
      id: attrs |> TrustEvidenceData.value(:id) |> TrustEvidenceData.required_ref!(:source_id),
      revision: attrs |> TrustEvidenceData.value(:revision, 1) |> TrustEvidenceData.positive_revision!()
    })
  end

  def new(_attrs), do: raise(ArgumentError, "trust evidence source must be a plain map")

  @doc "Returns stable source identity without its revision."
  @spec claim_key(t()) :: tuple()
  def claim_key(%__MODULE__{} = source), do: {source.kind, source.provider_id, source.id}

  defp default_provider(:message), do: "jido_messaging"
  defp default_provider(:provider_record), do: nil

  defp validate_provider!(:message, "jido_messaging"), do: :ok

  defp validate_provider!(:message, _provider),
    do: raise(ArgumentError, "message source provider must be jido_messaging")

  defp validate_provider!(:provider_record, _provider), do: :ok
end
