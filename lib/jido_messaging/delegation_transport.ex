defmodule Jido.Messaging.DelegationTransport do
  @moduledoc """
  Jidoka-owned delegation transport boundary for messaging.

  This module validates authorization subjects, canonical message references,
  duplicate identity, and loop trace. It does not choose agents, run
  subagents, change Jidoka ownership, or apply a handoff route.
  """

  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    JidokaDelegationContext,
    JidokaDelegationEvent,
    JidokaDelegationScope,
    Message,
    Runtime,
    Thread
  }

  @persistence_callbacks [
    save_jidoka_delegation_event: 2,
    get_jidoka_delegation_event: 2
  ]

  @doc "Records one authorized Jidoka-emitted delegation observation."
  @spec record(module(), GenServer.server(), map(), JidokaDelegationScope.t()) ::
          {:ok, JidokaDelegationEvent.t()} | {:error, term()}
  def record(instance_module, runtime, attrs, scope)
      when is_atom(instance_module) and not is_nil(instance_module) and is_map(attrs) do
    event = JidokaDelegationEvent.new(attrs)

    with :ok <- validate_scope(instance_module, scope, event),
         {:ok, event} <- JidokaDelegationEvent.enter(event, transport_node(instance_module)),
         {persistence, state} <- Runtime.get_persistence(runtime),
         :ok <- ensure_persistence(persistence),
         {:ok, _room} <- persistence.get_room(state, event.room_id),
         {:ok, %Thread{} = thread} <- persistence.get_thread(state, event.thread_id),
         :ok <- validate_thread(event, thread),
         {:ok, %Participant{} = source} <-
           persistence.get_participant(state, event.source_principal_id),
         :ok <- validate_agent_principal(source),
         {:ok, %Participant{} = target} <-
           persistence.get_participant(state, event.target_principal_id),
         :ok <- validate_agent_principal(target),
         {:ok, _messages} <- fetch_related_messages(persistence, state, event) do
      persistence.save_jidoka_delegation_event(state, event)
    end
  rescue
    ArgumentError -> {:error, :invalid_jidoka_delegation_event}
  end

  def record(_instance_module, _runtime, _attrs, _scope),
    do: {:error, :invalid_jidoka_delegation_event}

  @doc "Gets one delegation event within its exact authorization scope."
  @spec get(module(), GenServer.server(), String.t(), JidokaDelegationScope.t()) ::
          {:ok, JidokaDelegationEvent.t()} | {:error, term()}
  def get(instance_module, runtime, event_id, scope)
      when is_atom(instance_module) and not is_nil(instance_module) and is_binary(event_id) do
    with :ok <- validate_scope_instance(instance_module, scope),
         {persistence, state} <- Runtime.get_persistence(runtime),
         :ok <- ensure_persistence(persistence),
         {:ok, %JidokaDelegationEvent{} = event} <-
           persistence.get_jidoka_delegation_event(state, event_id),
         :ok <- validate_scope(instance_module, scope, event) do
      {:ok, event}
    end
  end

  def get(_instance_module, _runtime, _event_id, _scope),
    do: {:error, :invalid_jidoka_delegation_event_id}

  @doc "Returns only the canonical messages named by an authorized event."
  @spec context(module(), GenServer.server(), String.t(), JidokaDelegationScope.t()) ::
          {:ok, JidokaDelegationContext.t()} | {:error, term()}
  def context(instance_module, runtime, event_id, scope)
      when is_atom(instance_module) and not is_nil(instance_module) and is_binary(event_id) do
    with {:ok, %JidokaDelegationEvent{} = event} <-
           get(instance_module, runtime, event_id, scope),
         {persistence, state} <- Runtime.get_persistence(runtime),
         {:ok, messages} <- fetch_related_messages(persistence, state, event) do
      {:ok, JidokaDelegationContext.new(event, messages)}
    end
  end

  def context(_instance_module, _runtime, _event_id, _scope),
    do: {:error, :invalid_jidoka_delegation_event_id}

  defp ensure_persistence(persistence) do
    if Enum.all?(@persistence_callbacks, fn {name, arity} ->
         function_exported?(persistence, name, arity)
       end) do
      :ok
    else
      {:error, :jidoka_delegation_persistence_not_supported}
    end
  end

  defp validate_scope_instance(
         instance_module,
         %JidokaDelegationScope{instance_module: instance_module} = scope
       ) do
    JidokaDelegationScope.validate(scope)
  end

  defp validate_scope_instance(_instance_module, %JidokaDelegationScope{}),
    do: {:error, :jidoka_delegation_scope_instance_mismatch}

  defp validate_scope_instance(_instance_module, _scope),
    do: {:error, :jidoka_delegation_scope_required}

  defp validate_scope(instance_module, scope, event) do
    with :ok <- validate_scope_instance(instance_module, scope) do
      scope_identity =
        {scope.room_id, scope.thread_id, scope.source_principal_id, scope.target_principal_id}

      event_identity =
        {event.room_id, event.thread_id, event.source_principal_id, event.target_principal_id}

      if scope_identity == event_identity do
        :ok
      else
        {:error, :jidoka_delegation_scope_violation}
      end
    end
  end

  defp validate_thread(%JidokaDelegationEvent{room_id: room_id} = event, %Thread{room_id: room_id} = thread) do
    if JidokaDelegationEvent.deliverable?(event) and thread.status != :active do
      {:error, {:jidoka_delegation_thread_not_active, thread.status}}
    else
      :ok
    end
  end

  defp validate_thread(%JidokaDelegationEvent{}, %Thread{}),
    do: {:error, :jidoka_delegation_thread_room_mismatch}

  defp validate_agent_principal(%Participant{type: :agent}), do: :ok
  defp validate_agent_principal(%Participant{}), do: {:error, :jidoka_delegation_principal_not_agent}

  defp fetch_related_messages(persistence, state, event) do
    Enum.reduce_while(event.related_message_ids, {:ok, []}, fn message_id, {:ok, messages} ->
      case persistence.get_message(state, message_id) do
        {:ok, %Message{room_id: room_id, thread_id: thread_id} = message}
        when room_id == event.room_id and thread_id == event.thread_id ->
          {:cont, {:ok, [message | messages]}}

        {:ok, %Message{}} ->
          {:halt, {:error, :jidoka_delegation_message_scope_violation}}

        {:error, :not_found} ->
          {:halt, {:error, {:jidoka_delegation_message_not_found, message_id}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  defp transport_node(instance_module), do: "jido_messaging:#{Atom.to_string(instance_module)}"
end
