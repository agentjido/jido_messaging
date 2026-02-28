defmodule Jido.Messaging.PubSub do
  @moduledoc """
  Optional Phoenix.PubSub integration for cross-node events and LiveView support.

  This module provides publish/subscribe functionality for room events when
  Phoenix.PubSub is available. All functions gracefully handle cases where
  PubSub is not configured.

  ## Usage

      defmodule MyApp.Messaging do
        use Jido.Messaging,
          adapter: Jido.Messaging.Adapters.ETS,
          pubsub: MyApp.PubSub
      end

      # Subscribe to room events
      MyApp.Messaging.subscribe("room_123")

      # Events received:
      # {:message_added, %Message{}}
      # {:participant_joined, %Participant{}}
      # {:participant_left, participant_id}
  """

  @doc """
  Check if Phoenix.PubSub is available at runtime.
  """
  @spec pubsub_available?() :: boolean()
  def pubsub_available? do
    Code.ensure_loaded?(Phoenix.PubSub)
  end

  @doc """
  Check if PubSub is configured for the given instance module.
  """
  @spec configured?(module()) :: boolean()
  def configured?(instance_module) do
    pubsub_available?() and not is_nil(get_pubsub(instance_module))
  end

  @doc """
  Subscribe to events for a room.

  Returns `:ok` on success, or `{:error, :not_configured}` if PubSub is not configured.
  """
  @spec subscribe(module(), String.t()) :: :ok | {:error, :not_configured}
  def subscribe(instance_module, room_id) do
    with_pubsub(instance_module, fn pubsub ->
      apply(Phoenix.PubSub, :subscribe, [pubsub, topic(room_id)])
    end)
  end

  @doc """
  Unsubscribe from events for a room.

  Returns `:ok` on success, or `{:error, :not_configured}` if PubSub is not configured.
  """
  @spec unsubscribe(module(), String.t()) :: :ok | {:error, :not_configured}
  def unsubscribe(instance_module, room_id) do
    with_pubsub(instance_module, fn pubsub ->
      apply(Phoenix.PubSub, :unsubscribe, [pubsub, topic(room_id)])
    end)
  end

  @doc """
  Broadcast an event to all subscribers of a room.

  Returns `:ok` on success, or `{:error, :not_configured}` if PubSub is not configured.
  """
  @spec broadcast(module(), String.t(), term()) :: :ok | {:error, :not_configured}
  def broadcast(instance_module, room_id, event) do
    with_pubsub(instance_module, fn pubsub ->
      apply(Phoenix.PubSub, :broadcast, [pubsub, topic(room_id), event])
    end)
  end

  defp with_pubsub(instance_module, fun) do
    case get_pubsub(instance_module) do
      nil ->
        {:error, :not_configured}

      pubsub ->
        if pubsub_available?() do
          fun.(pubsub)
        else
          {:error, :not_configured}
        end
    end
  end

  @doc """
  Generate the topic string for a room.
  """
  @spec topic(String.t()) :: String.t()
  def topic(room_id) do
    "jido_messaging:rooms:#{room_id}"
  end

  @doc false
  def get_pubsub(instance_module) do
    if function_exported?(instance_module, :__jido_messaging__, 1) do
      instance_module.__jido_messaging__(:pubsub)
    else
      nil
    end
  end
end
