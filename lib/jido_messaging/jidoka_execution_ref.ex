defmodule Jido.Messaging.JidokaExecutionRef do
  @moduledoc """
  Opaque correlation from messaging history to Jidoka-owned execution detail.

  The reference contains identifiers and availability only. It does not contain
  a Jidoka event, trace, prompt, tool argument, model output, or memory value.
  """

  alias Jido.Messaging.ActivityData

  @schema Zoi.struct(
            __MODULE__,
            %{
              integration_id: Zoi.string(),
              session_id: Zoi.string(),
              request_id: Zoi.string(),
              turn_id: Zoi.string() |> Zoi.nullish(),
              handoff_id: Zoi.string() |> Zoi.nullish(),
              approval_id: Zoi.string() |> Zoi.nullish(),
              detail_ref: Zoi.string() |> Zoi.nullish(),
              detail_availability: Zoi.enum([:available, :unavailable, :expired, :restricted]),
              detail_expires_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type detail_availability :: :available | :unavailable | :expired | :restricted
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :integration_id,
    :session_id,
    :request_id,
    :turn_id,
    :handoff_id,
    :approval_id,
    :detail_ref,
    :detail_availability,
    :detail_expires_at
  ]

  @doc "Returns the Zoi schema for JidokaExecutionRef."
  def schema, do: @schema

  @doc "Builds a strict, opaque Jidoka execution reference."
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = reference), do: reference |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    :ok = ActivityData.strict_keys!(attrs, @allowed_keys)
    availability = attrs |> ActivityData.value(:detail_availability, :unavailable) |> normalize_availability!()
    detail_ref = attrs |> ActivityData.value(:detail_ref) |> ActivityData.optional_ref!(:detail_ref)
    detail_expires_at = ActivityData.value(attrs, :detail_expires_at)

    if availability == :available and is_nil(detail_ref) do
      raise ArgumentError, "available Jidoka detail requires detail_ref"
    end

    if availability in [:unavailable, :expired] and not is_nil(detail_ref) do
      raise ArgumentError, "unavailable or expired Jidoka detail cannot keep detail_ref"
    end

    if not is_nil(detail_expires_at) and not match?(%DateTime{}, detail_expires_at) do
      raise ArgumentError, "detail_expires_at must be a DateTime"
    end

    normalized = %{
      integration_id: attrs |> ActivityData.value(:integration_id) |> ActivityData.required_ref!(:integration_id),
      session_id: attrs |> ActivityData.value(:session_id) |> ActivityData.required_ref!(:session_id),
      request_id: attrs |> ActivityData.value(:request_id) |> ActivityData.required_ref!(:request_id),
      turn_id: attrs |> ActivityData.value(:turn_id) |> ActivityData.optional_ref!(:turn_id),
      handoff_id: attrs |> ActivityData.value(:handoff_id) |> ActivityData.optional_ref!(:handoff_id),
      approval_id: attrs |> ActivityData.value(:approval_id) |> ActivityData.optional_ref!(:approval_id),
      detail_ref: detail_ref,
      detail_availability: availability,
      detail_expires_at: detail_expires_at
    }

    Jido.Chat.Schema.parse!(__MODULE__, @schema, normalized)
  end

  def new(_attrs), do: raise(ArgumentError, "execution_ref must be a map")

  @doc "Returns the stable execution correlation fields without detail availability."
  @spec correlation_key(t()) :: tuple()
  def correlation_key(%__MODULE__{} = reference) do
    {
      reference.integration_id,
      reference.session_id,
      reference.request_id,
      reference.turn_id,
      reference.handoff_id,
      reference.approval_id
    }
  end

  @doc "Returns an effective reference that hides a detail link after its expiry."
  @spec effective(t(), DateTime.t()) :: t()
  def effective(%__MODULE__{} = reference, at \\ DateTime.utc_now()) do
    if reference.detail_availability == :available and
         match?(%DateTime{}, reference.detail_expires_at) and
         DateTime.compare(at, reference.detail_expires_at) != :lt do
      %{reference | detail_availability: :expired, detail_ref: nil}
    else
      reference
    end
  end

  defp normalize_availability!(availability)
       when availability in [:available, :unavailable, :expired, :restricted],
       do: availability

  defp normalize_availability!("available"), do: :available
  defp normalize_availability!("unavailable"), do: :unavailable
  defp normalize_availability!("expired"), do: :expired
  defp normalize_availability!("restricted"), do: :restricted
  defp normalize_availability!(_availability), do: raise(ArgumentError, "invalid detail availability")
end
