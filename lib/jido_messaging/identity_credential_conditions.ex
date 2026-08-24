defmodule Jido.Messaging.IdentityCredentialConditions do
  @moduledoc """
  Canonical audience and room conditions for a controller credential.

  Conditions identify where the controller relation can be verified. They do
  not contain messaging actions and are not a reusable capability.
  """

  alias Jido.Messaging.IdentityData

  @schema Zoi.struct(
            __MODULE__,
            %{
              audience: Zoi.string(),
              room_ids: Zoi.array(Zoi.string())
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for IdentityCredentialConditions."
  def schema, do: @schema

  @doc "Builds strict audience and canonical room conditions."
  @spec new(t() | map()) :: t()
  def new(%__MODULE__{} = conditions), do: conditions |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    allowed_keys = [:audience, :room_ids, "audience", "room_ids"]

    if Map.keys(attrs) -- allowed_keys != [] do
      raise ArgumentError, "identity credential conditions permit only audience and room_ids"
    end

    attrs = %{
      audience: attrs |> IdentityData.value(:audience) |> IdentityData.required!(:audience),
      room_ids:
        attrs
        |> IdentityData.value(:room_ids, [])
        |> IdentityData.string_list!(:room_ids, non_empty: true)
    }

    Jido.Chat.Schema.parse!(__MODULE__, @schema, attrs)
  end
end
