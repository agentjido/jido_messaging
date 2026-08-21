defmodule Jido.Messaging.ReadReceipt do
  @moduledoc """
  Maps a provider-confirmed read operation to a persisted runtime message.

  The provider operation completes before persistence changes. A provider
  failure or unsupported adapter therefore leaves the local message unchanged.
  """

  alias Jido.Messaging.{
    AdapterBridge,
    BridgeConfig,
    ConfigStore,
    Message,
    RoomBinding,
    Runtime,
    SecretResolver
  }

  @type persistence_result :: {:ok, Message.t(), :updated | :unchanged} | {:error, term()}

  @doc "Marks a provider message as read and persists the normalized receipt."
  @spec mark_as_read(module(), GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def mark_as_read(instance_module, runtime, message_id, participant_id, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(participant_id) and
             is_list(opts) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    with {:ok, message} <- persistence.get_message(persistence_state, message_id),
         {:ok, bridge_id} <- resolve_bridge_id(message, opts),
         :miss <- provider_receipt_status(message, participant_id, bridge_id),
         {:ok, read_at} <- resolve_read_at(opts),
         {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         {:ok, external_room_id} <- resolve_external_room_id(persistence, persistence_state, message, bridge_id, opts),
         {:ok, external_message_id} <- resolve_external_message_id(message, opts),
         {:ok, adapter_opts} <- adapter_opts(instance_module, config, message, participant_id, bridge_id, opts),
         :ok <-
           AdapterBridge.mark_as_read(
             config.adapter_module,
             external_room_id,
             external_message_id,
             adapter_opts
           ),
         {:ok, updated, _change} <-
           persist(
             persistence,
             persistence_state,
             message_id,
             participant_id,
             receipt(bridge_id, external_message_id, read_at)
           ) do
      {:ok, updated}
    else
      {:already_read, %Message{} = message} -> {:ok, message}
      {:error, _reason} = error -> error
    end
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
      do: {:already_read, message},
      else: :miss
  end

  defp fetch_bridge(instance_module, bridge_id) do
    case ConfigStore.get_bridge_config(instance_module, bridge_id) do
      {:ok, %BridgeConfig{enabled: true} = config} -> {:ok, config}
      {:ok, %BridgeConfig{enabled: false}} -> {:error, :bridge_disabled}
      {:error, :not_found} -> {:error, :bridge_not_found}
    end
  end

  defp resolve_bridge_id(message, opts) do
    case opts[:bridge_id] || metadata_value(message.metadata, :bridge_id) do
      bridge_id when is_binary(bridge_id) and bridge_id != "" -> {:ok, bridge_id}
      bridge_id when not is_nil(bridge_id) -> {:ok, to_string(bridge_id)}
      _missing -> {:error, :missing_bridge_id}
    end
  end

  defp resolve_external_room_id(persistence, state, message, bridge_id, opts) do
    direct = opts[:external_room_id] || message.delivery_external_room_id

    if present?(direct) do
      {:ok, direct}
    else
      with {:ok, bindings} <- persistence.list_room_bindings(state, message.room_id) do
        case Enum.find(bindings, &match?(%RoomBinding{bridge_id: ^bridge_id}, &1)) do
          %RoomBinding{} = binding ->
            {:ok, binding.external_room_id}

          nil ->
            external_room_id_from_room(persistence, state, message.room_id, bridge_id)
        end
      end
    end
  end

  defp external_room_id_from_room(persistence, state, room_id, bridge_id) do
    with {:ok, room} <- persistence.get_room(state, room_id),
         external_room_id when not is_nil(external_room_id) <-
           find_external_room_id(room.external_bindings || %{}, bridge_id) do
      {:ok, external_room_id}
    else
      nil -> {:error, :missing_external_room_id}
      {:error, _reason} = error -> error
    end
  end

  defp find_external_room_id(external_bindings, bridge_id) do
    Enum.find_value(external_bindings, fn {_channel, bridge_bindings} ->
      Map.get(bridge_bindings, bridge_id) || Map.get(bridge_bindings, to_string(bridge_id))
    end)
  end

  defp resolve_external_message_id(message, opts) do
    case opts[:external_message_id] || message.external_id do
      nil -> {:error, :missing_external_message_id}
      value -> {:ok, value}
    end
  end

  defp adapter_opts(instance_module, config, message, participant_id, bridge_id, opts) do
    base_opts =
      config.opts
      |> Enum.reduce([], fn
        {key, value}, acc when is_atom(key) -> Keyword.put(acc, key, value)
        _entry, acc -> acc
      end)
      |> Keyword.merge(Keyword.get(opts, :adapter_opts, []))

    with {:ok, adapter_opts} <-
           SecretResolver.adapter_opts_for_config(instance_module, config, :mark_as_read, base_opts) do
      {:ok,
       adapter_opts
       |> Keyword.put(:participant_id, participant_id)
       |> Keyword.put(:local_message_id, message.id)
       |> Keyword.put(:bridge_id, bridge_id)}
    end
  end

  defp receipt(bridge_id, external_message_id, read_at) do
    %{
      bridge_id: bridge_id,
      external_message_id: external_message_id,
      read_at: read_at
    }
  end

  defp resolve_read_at(opts) do
    case Keyword.fetch(opts, :read_at) do
      {:ok, %DateTime{} = read_at} -> {:ok, read_at}
      {:ok, _invalid} -> {:error, :invalid_read_at}
      :error -> {:ok, DateTime.utc_now()}
    end
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

  defp metadata_value(metadata, key) do
    Map.get(metadata || %{}, key) || Map.get(metadata || %{}, Atom.to_string(key))
  end

  defp present?(value), do: not is_nil(value) and value != ""
end
