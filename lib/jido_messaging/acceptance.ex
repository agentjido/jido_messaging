defmodule Jido.Messaging.Acceptance do
  @moduledoc false
  alias Jido.Chat.{Binding, Delivery}
  alias Jido.Chat.Errors.Contract
  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.{AdapterBridge, Deduper, Dispatch, Events, Ingest, MessageLifecycle, Runtime}

  @doc false
  @spec accept(module(), Delivery.t()) :: {:ok, [Jido.Signal.t()]} | {:error, term()}
  def accept(_instance, %Delivery{signals: []} = delivery) do
    with {:ok, _} <- Delivery.validate_empty(delivery), do: {:ok, []}
  end

  def accept(instance, %Delivery{signals: [%Jido.Signal{} = first | _]} = delivery) do
    with {:ok, binding} <- Runtime.binding(instance.__jido_messaging__(:runtime), first.source),
         {:ok, delivery} <- Delivery.validate(binding, delivery),
         true <- Enum.all?(delivery.signals, &(byte_size(&1.id) in 1..128)) do
      Enum.reduce_while(delivery.signals, {:ok, []}, fn parent, {:ok, signals} ->
        case accept_item(instance, binding, parent) do
          {:ok, child_signals} -> {:cont, {:ok, signals ++ child_signals}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> Policy.error(:invalid_context)
    end
  end

  def accept(_instance, _delivery), do: Policy.error(:invalid_delivery)

  defp accept_item(instance, binding, parent) do
    key = {:chat_fact, binding.source, parent.type, parent.data["item_id"]}

    case Deduper.claim(instance, key) do
      {:error, :outcome_unknown} ->
        Policy.error(:request_outcome_unknown)

      :duplicate ->
        {:ok, []}

      {:ok, token} ->
        case process_safely(instance, binding, parent) do
          {:ok, signals} ->
            _ = Deduper.commit(instance, key, token)
            # Observation errors do not release an authoritative acceptance claim.
            _ = Dispatch.emit(instance, parent)
            Enum.each(signals, &Dispatch.emit(instance, &1))
            {:ok, signals}

          {:error, %Contract{code: :request_outcome_unknown}} = error ->
            _ = Deduper.retain_unknown(instance, key, token)
            error

          error ->
            _ = Deduper.release(instance, key, token)
            acceptance_error(error)
        end
    end
  end

  defp process_safely(instance, binding, parent) do
    process(instance, binding, parent)
  rescue
    _ -> Policy.error(:handler_failed)
  catch
    _, _ -> Policy.error(:handler_failed)
  end

  defp process(instance, %Binding{} = binding, %{type: "jido.chat.message.received"} = parent) do
    with {:ok, message, context} <- Ingest.accept_fact(instance, binding, parent) do
      case Events.message_received(instance, message,
             bridge_id: context.bridge_id,
             external_room_id: context.external_room_id,
             parent_signal: parent
           ) do
        {:ok, child} ->
          {:ok, [child]}

        {:error, _} ->
          {:ok, failure} =
            Events.message_failed(instance, message.room_id, :observation_failed,
              message_id: message.id,
              bridge_id: binding.id,
              parent_signal: parent
            )

          {:ok, [failure]}
      end
    else
      {:ok, :duplicate} -> {:ok, []}
      error -> error
    end
  end

  defp process(instance, binding, %{type: "jido.chat.membership.changed"} = parent) do
    with {:ok, room} <- membership_room(instance, binding, parent) do
      data =
        parent.data
        |> Map.take(~w(participant_id actor_id bot_self transition evidence previous current))
        |> Map.put("binding_id", binding.id)
        |> Map.put("external_room_id", parent.data["room_id"])
        |> Map.put("room_id", room)

      with {:ok, signal} <-
             Events.new("jido.messaging.membership.observed", instance, room, data, parent_signal: parent),
           do: {:ok, [signal]}
    end
  end

  defp process(instance, binding, %{type: type} = parent)
       when type in ["jido.chat.message.updated", "jido.chat.message.deleted"] do
    case MessageLifecycle.apply(instance, AdapterBridge.channel_type(binding.adapter), binding.id, parent) do
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  defp process(_instance, _binding, _parent), do: {:ok, []}

  defp membership_room(instance, binding, parent) do
    case instance.get_room_by_external_binding(
           AdapterBridge.channel_type(binding.adapter),
           binding.id,
           parent.data["room_id"]
         ) do
      {:ok, %Jido.Chat.Room{id: room}} when is_binary(room) and room != "" -> {:ok, room}
      {:error, :not_found} -> {:ok, nil}
      _ -> Policy.error(:handler_failed)
    end
  rescue
    _ -> Policy.error(:handler_failed)
  catch
    _, _ -> Policy.error(:handler_failed)
  end

  defp acceptance_error({:error, %Contract{}} = error), do: error
  defp acceptance_error(_error), do: Policy.error(:handler_failed)
end
