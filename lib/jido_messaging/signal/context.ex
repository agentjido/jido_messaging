defmodule Jido.Messaging.Signal.Context do
  @moduledoc false

  alias Jido.Signal
  alias Jido.Signal.{Context, Trace}

  @doc "Adds native trace metadata and the direct parent cause to a checked Signal."
  @spec attach(Signal.t(), keyword()) :: {:ok, Signal.t()} | {:error, term()}
  def attach(%Signal{} = signal, opts) do
    result =
      case Keyword.get(opts, :parent_signal) do
        nil -> root(signal, opts)
        %Signal{id: id} = parent when is_binary(id) and byte_size(id) in 1..128 -> child(signal, parent)
        _ -> Jido.Chat.Signal.Policy.error(:invalid_context)
      end

    with {:ok, attached} <- result, do: Jido.Chat.Signal.Policy.validate(attached)
  end

  defp root(signal, opts) do
    with {:ok, signal, _trace} <- Trace.ensure(signal) do
      case Keyword.get(opts, :causation_id) do
        nil ->
          {:ok, signal}

        parent_id when is_binary(parent_id) and byte_size(parent_id) in 1..128 ->
          Context.put(signal, "causationid", parent_id)

        _ ->
          Jido.Chat.Signal.Policy.error(:invalid_context)
      end
    end
  end

  defp child(signal, parent) do
    with {:ok, _validated} <- parent |> Signal.to_map() |> Signal.from_map(),
         {:ok, signal} <- Trace.put(signal, Trace.child(Trace.get(parent) || Trace.new())),
         {:ok, signal} <- Context.put(signal, "causationid", parent.id) do
      {:ok, signal}
    end
  end
end
