defmodule Jido.Messaging.AgentDirectoryEndpointRef do
  @moduledoc """
  Safe reference to a canonical Jido Messaging agent endpoint.

  The reference does not contain delivery data, membership, credentials, or
  Jidoka runtime state.
  """

  alias Jido.Messaging.AgentDirectoryData

  @schema Zoi.struct(
            __MODULE__,
            %{
              system: Zoi.string(),
              id: Zoi.string()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AgentDirectoryEndpointRef."
  def schema, do: @schema

  @doc "Builds a strict endpoint reference."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = reference), do: reference |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    :ok = AgentDirectoryData.strict_keys!(attrs, [:system, :id], "agent endpoint reference")
    system = AgentDirectoryData.value(attrs, :system)

    if system not in [:jido_messaging, "jido_messaging"] do
      raise ArgumentError, "agent endpoint reference system must be jido_messaging"
    end

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      system: "jido_messaging",
      id: attrs |> AgentDirectoryData.value(:id) |> AgentDirectoryData.required_ref!(:endpoint_id)
    })
  end

  def new(_attrs), do: raise(ArgumentError, "agent endpoint reference must be a map")
end
