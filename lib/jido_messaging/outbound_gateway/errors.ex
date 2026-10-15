defmodule Jido.Messaging.OutboundGateway.Errors do
  @moduledoc false
  alias Jido.Messaging.OutboundGateway

  def validate(request) when is_map(request) do
    cond do
      request[:operation] not in [:send, :edit, :send_media, :edit_media] ->
        {:error, {:invalid_request, :operation}}

      not is_atom(request[:channel]) ->
        {:error, {:invalid_request, :channel}}

      is_nil(request[:external_room_id]) ->
        {:error, {:invalid_request, :external_room_id}}

      not valid_payload?(request[:operation], request[:payload]) ->
        {:error, {:invalid_request, :payload}}

      request[:priority] not in [:critical, :high, :normal, :low] ->
        {:error, {:invalid_request, :priority}}

      request[:operation] in [:edit, :edit_media] and is_nil(request[:external_message_id]) ->
        {:error, :missing_external_message_id}

      true ->
        :ok
    end
  end

  def validate(_request), do: {:error, :invalid_request}

  defp valid_payload?(operation, payload) when operation in [:send, :edit], do: is_binary(payload)
  defp valid_payload?(operation, payload) when operation in [:send_media, :edit_media], do: is_map(payload)
  defp valid_payload?(_operation, _payload), do: false

  def invalid(request, reason, state) do
    request = if is_map(request), do: request, else: %{}

    %{
      type: :outbound_error,
      category: OutboundGateway.classify_error(reason),
      disposition: :terminal,
      operation: request[:operation] || :send,
      reason: reason,
      attempt: 1,
      max_attempts: state.max_attempts,
      partition: state.partition,
      routing_key: request[:routing_key] || "unknown:unknown",
      retryable: false
    }
  end

  def queue_full(request, state) do
    %{
      type: :outbound_error,
      category: :terminal,
      disposition: :terminal,
      operation: request[:operation] || :send,
      reason: :queue_full,
      attempt: 1,
      max_attempts: state.max_attempts,
      partition: state.partition,
      routing_key: request[:routing_key] || "unknown:unknown",
      retryable: false
    }
  end

  def load_shed(request, state) do
    %{
      type: :outbound_error,
      category: :terminal,
      disposition: :terminal,
      operation: request[:operation] || :send,
      reason: :load_shed,
      attempt: 1,
      max_attempts: state.max_attempts,
      partition: state.partition,
      routing_key: request[:routing_key] || "unknown:unknown",
      retryable: false
    }
  end
end
