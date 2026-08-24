defmodule Jido.Messaging.MessagingActivitySummary do
  @moduledoc """
  Bounded operator summary for a projected Jidoka activity.

  Free-form runtime data is not part of this contract. A Jidoka-owned adapter
  must redact the optional display label before it supplies the projection.
  """

  alias Jido.Messaging.ActivityData

  @schema Zoi.struct(
            __MODULE__,
            %{
              outcome: Zoi.enum([:none, :succeeded, :failed, :denied, :cancelled, :unknown]),
              code: Zoi.string() |> Zoi.nullish(),
              label: Zoi.string() |> Zoi.nullish()
            },
            coerce: true
          )

  @type outcome :: :none | :succeeded | :failed | :denied | :cancelled | :unknown
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [:outcome, :code, :label]

  @doc "Returns the Zoi schema for MessagingActivitySummary."
  def schema, do: @schema

  @doc "Builds a strict status code and redacted display summary."
  @spec new(t() | map() | nil) :: t()
  def new(nil), do: new(%{})
  def new(%__MODULE__{} = summary), do: summary |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    :ok = ActivityData.strict_keys!(attrs, @allowed_keys)

    normalized = %{
      outcome: attrs |> ActivityData.value(:outcome, :unknown) |> normalize_outcome!(),
      code: attrs |> ActivityData.value(:code) |> ActivityData.optional_code!(),
      label: attrs |> ActivityData.value(:label) |> ActivityData.optional_label!()
    }

    Jido.Chat.Schema.parse!(__MODULE__, @schema, normalized)
  end

  def new(_attrs), do: raise(ArgumentError, "activity summary must be a map")

  defp normalize_outcome!(outcome) when outcome in [:none, :succeeded, :failed, :denied, :cancelled, :unknown],
    do: outcome

  defp normalize_outcome!("none"), do: :none
  defp normalize_outcome!("succeeded"), do: :succeeded
  defp normalize_outcome!("failed"), do: :failed
  defp normalize_outcome!("denied"), do: :denied
  defp normalize_outcome!("cancelled"), do: :cancelled
  defp normalize_outcome!("unknown"), do: :unknown
  defp normalize_outcome!(_outcome), do: raise(ArgumentError, "invalid activity outcome")
end
