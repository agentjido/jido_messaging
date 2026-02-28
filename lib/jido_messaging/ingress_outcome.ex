defmodule Jido.Messaging.IngressOutcome do
  @moduledoc """
  Canonical normalized ingress result for webhook and non-webhook payload paths.
  """

  alias Jido.Chat.{EventEnvelope, WebhookResponse}

  @schema Zoi.struct(
            __MODULE__,
            %{
              mode: Zoi.atom(),
              bridge_id: Zoi.string(),
              status: Zoi.atom(),
              envelope: Zoi.struct(EventEnvelope) |> Zoi.nullish(),
              message: Zoi.any() |> Zoi.nullish(),
              context: Zoi.any() |> Zoi.nullish(),
              response: Zoi.struct(WebhookResponse) |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc "Builds an ingress outcome from attrs."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)
end
