defmodule Jido.Messaging.ReadReceipt do
  @moduledoc """
  Maps a provider-confirmed read operation to a persisted runtime message.

  The provider operation completes before persistence changes. A provider
  failure or unsupported adapter therefore leaves the local message unchanged.
  """

  alias Jido.Messaging.{Message, Runtime}

  @doc false
  @spec prepare(GenServer.server(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(runtime, data, principal_id) do
    with {:ok, message} <- Jido.Messaging.get_message(runtime, data["message_id"]),
         {:ok, principal} <- Jido.Messaging.get_principal(runtime, principal_id),
         true <- message.room_id == data["room_id"],
         true <- is_binary(principal.participant_id),
         true <- is_binary(message.external_id) and message.external_id != "",
         true <- origin_matches?(message, data["bridge_id"]),
         {:ok, read_at} <- read_at(data["read_at"]) do
      {:ok,
       %{
         message: message,
         participant_id: principal.participant_id,
         bridge_id: data["bridge_id"],
         external_message_id: message.external_id,
         read_at: read_at,
         already_read: provider_receipt_status(message, principal.participant_id, data["bridge_id"]) == :already_read
       }}
    else
      false -> {:error, :receipt_scope_mismatch}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec commit(GenServer.server(), map()) :: {:ok, Message.t(), :updated | :unchanged} | {:error, term()}
  def commit(runtime, plan) do
    {persistence, state} = Runtime.get_persistence(runtime)
    receipt = %{bridge_id: plan.bridge_id, external_message_id: plan.external_message_id, read_at: plan.read_at}

    persistence
    |> persist(state, plan.message.id, plan.participant_id, receipt)
    |> committed_receipt(plan)
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp committed_receipt({:ok, %Message{} = message, change}, plan) when change in [:updated, :unchanged] do
    expected_read = %{external_message_id: plan.external_message_id, read_at: plan.read_at}

    provider_read =
      message.receipts
      |> Map.get(plan.participant_id, %{})
      |> Map.get(:provider_reads, %{})
      |> Map.get(plan.bridge_id)

    if Message.new(Map.from_struct(message)) == message and
         message.id == plan.message.id and message.room_id == plan.message.room_id and
         message.external_id == plan.external_message_id and message.status == :read and
         is_map(provider_read) and provider_read[:external_message_id] == plan.external_message_id and
         match?(%DateTime{}, provider_read[:read_at]) and
         (change == :unchanged or provider_read == expected_read) do
      {:ok, message, change}
    else
      {:error, :invalid_receipt_result}
    end
  end

  defp committed_receipt({:error, _} = error, _plan), do: error
  defp committed_receipt(_result, _plan), do: {:error, :invalid_receipt_result}

  defp read_at(nil), do: {:ok, DateTime.utc_now()}

  defp read_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> {:ok, date}
      _ -> Jido.Chat.Signal.Policy.error(:invalid_request, :read_at)
    end
  end

  defp origin_matches?(message, bridge) do
    origin = Map.get(message.metadata, :bridge_id) || Map.get(message.metadata, "bridge_id")
    is_nil(origin) or origin == bridge
  end

  @doc false
  @spec apply_to_message(Message.t(), String.t(), map()) ::
          {Message.t(), :updated | :unchanged}
  def apply_to_message(%Message{} = message, participant_id, receipt)
      when is_binary(participant_id) and is_map(receipt) do
    bridge_id = Map.fetch!(receipt, :bridge_id)
    read_at = Map.fetch!(receipt, :read_at)
    existing_receipt = Map.get(message.receipts || %{}, participant_id, %{})
    provider_reads = Map.get(existing_receipt, :provider_reads, %{})

    if Map.has_key?(provider_reads, bridge_id) do
      {message, :unchanged}
    else
      provider_read = %{
        external_message_id: Map.fetch!(receipt, :external_message_id),
        read_at: read_at
      }

      updated_receipt =
        existing_receipt
        |> Map.put_new(:delivered_at, read_at)
        |> Map.put_new(:read_at, read_at)
        |> Map.put(:provider_reads, Map.put(provider_reads, bridge_id, provider_read))

      updated = %{
        message
        | status: :read,
          receipts: Map.put(message.receipts || %{}, participant_id, updated_receipt),
          updated_at: read_at
      }

      {updated, :updated}
    end
  end

  defp provider_receipt_status(message, participant_id, bridge_id) do
    provider_reads =
      message.receipts
      |> Map.get(participant_id, %{})
      |> Map.get(:provider_reads, %{})

    if Map.has_key?(provider_reads, bridge_id),
      do: :already_read,
      else: :miss
  end

  defp persist(persistence, state, message_id, participant_id, receipt) do
    if function_exported?(persistence, :mark_message_read, 4) do
      persistence.mark_message_read(state, message_id, participant_id, receipt)
    else
      persist_with_fallback(persistence, state, message_id, participant_id, receipt)
    end
  end

  defp persist_with_fallback(persistence, state, message_id, participant_id, receipt) do
    with {:ok, message} <- persistence.get_message(state, message_id) do
      case apply_to_message(message, participant_id, receipt) do
        {updated, :updated} ->
          with {:ok, saved} <- persistence.save_message(state, updated) do
            {:ok, saved, :updated}
          end

        {unchanged, :unchanged} ->
          {:ok, unchanged, :unchanged}
      end
    end
  end
end
