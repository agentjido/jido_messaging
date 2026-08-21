defmodule Jido.Messaging.HistoryScope do
  @moduledoc """
  Mandatory instance and room authorization scope for history operations.

  The caller must supply the rooms that its authorization policy permits.
  History queries never expand this list.
  """

  @enforce_keys [:instance_module, :room_ids]
  defstruct [:instance_module, :room_ids, metadata: %{}]

  @type t :: %__MODULE__{
          instance_module: module(),
          room_ids: [String.t()],
          metadata: map()
        }

  @doc "Builds an explicit history scope for one messaging instance."
  @spec new(module(), [String.t()], map()) :: {:ok, t()} | {:error, :invalid_history_scope}
  def new(instance_module, room_ids, metadata \\ %{})

  def new(instance_module, room_ids, metadata)
      when is_atom(instance_module) and is_list(room_ids) and is_map(metadata) do
    room_ids = room_ids |> Enum.uniq() |> Enum.sort()

    if Enum.all?(room_ids, &(is_binary(&1) and &1 != "")) do
      {:ok, %__MODULE__{instance_module: instance_module, room_ids: room_ids, metadata: metadata}}
    else
      {:error, :invalid_history_scope}
    end
  end

  def new(_instance_module, _room_ids, _metadata), do: {:error, :invalid_history_scope}

  @doc "Builds a history scope and raises for invalid input."
  @spec new!(module(), [String.t()], map()) :: t()
  def new!(instance_module, room_ids, metadata \\ %{}) do
    case new(instance_module, room_ids, metadata) do
      {:ok, scope} -> scope
      {:error, :invalid_history_scope} -> raise ArgumentError, "invalid history scope"
    end
  end
end
