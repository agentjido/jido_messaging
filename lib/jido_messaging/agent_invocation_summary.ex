defmodule Jido.Messaging.AgentInvocationSummary do
  @moduledoc """
  Safe, non-authoritative summary of how a Jidoka agent accepts messages.

  This summary is display data. It is not an invocation grant or policy
  decision.
  """

  alias Jido.Messaging.AgentDirectoryData

  @modes [:message, :thread, :room]
  @approval_states [:unknown, :not_required, :may_require, :required]

  @schema Zoi.struct(
            __MODULE__,
            %{
              mode: Zoi.enum(@modes),
              approval: Zoi.enum(@approval_states)
            },
            coerce: true
          )

  @type mode :: :message | :thread | :room
  @type approval :: :unknown | :not_required | :may_require | :required
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AgentInvocationSummary."
  def schema, do: @schema

  @doc "Builds a strict invocation summary."
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = summary), do: summary |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    :ok = AgentDirectoryData.strict_keys!(attrs, [:mode, :approval], "invocation summary")

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      mode: attrs |> AgentDirectoryData.value(:mode) |> AgentDirectoryData.enum!(@modes, :invocation_mode),
      approval:
        attrs
        |> AgentDirectoryData.value(:approval, :unknown)
        |> AgentDirectoryData.enum!(@approval_states, :approval_summary)
    })
  end

  def new(_attrs), do: raise(ArgumentError, "invocation summary must be a map")
end
