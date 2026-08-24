defmodule Jido.Messaging.ActivityProjection do
  @moduledoc false

  alias Jido.Chat.Participant
  alias Jido.Messaging.{HistoryScope, MessagingActivityEntry, Runtime, Thread}

  @doc false
  @spec project(atom(), map()) :: {:ok, MessagingActivityEntry.t()} | {:error, term()}
  def project(runtime, attrs) when is_atom(runtime) and is_map(attrs) do
    entry = MessagingActivityEntry.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <-
           require_callbacks(persistence,
             save_messaging_activity: 2,
             get_messaging_activity: 2
           ) do
      case persistence.get_messaging_activity(state, entry.id) do
        {:ok, _stored} ->
          persistence.save_messaging_activity(state, entry)

        {:error, :not_found} ->
          with {:ok, %Participant{} = principal} <- persistence.get_participant(state, entry.principal_id),
               :ok <- validate_agent_principal(principal),
               {:ok, _room} <- persistence.get_room(state, entry.room_id),
               :ok <- validate_thread(persistence, state, entry),
               :ok <- validate_message(persistence, state, entry) do
            persistence.save_messaging_activity(state, entry)
          end

        {:error, _reason} = error ->
          error
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_messaging_activity_projection}
  end

  @doc false
  @spec principal_activity(module(), atom(), String.t(), HistoryScope.t(), keyword()) ::
          {:ok, [MessagingActivityEntry.t()]} | {:error, term()}
  def principal_activity(instance_module, runtime, principal_id, scope, opts \\ [])
      when is_atom(instance_module) and is_atom(runtime) and is_binary(principal_id) and is_list(opts) do
    with :ok <- validate_scope(instance_module, scope),
         {persistence, state} <- Runtime.get_persistence(runtime),
         :ok <- require_callbacks(persistence, get_principal_activity: 4),
         {:ok, %Participant{} = principal} <- persistence.get_participant(state, principal_id),
         :ok <- validate_agent_principal(principal) do
      with {:ok, entries} <- persistence.get_principal_activity(state, principal_id, scope.room_ids, opts) do
        now = DateTime.utc_now()
        {:ok, Enum.map(entries, &MessagingActivityEntry.with_effective_detail(&1, now))}
      end
    end
  end

  defp validate_thread(_persistence, _state, %MessagingActivityEntry{thread_id: nil}), do: :ok

  defp validate_thread(persistence, state, %MessagingActivityEntry{} = entry) do
    case persistence.get_thread(state, entry.thread_id) do
      {:ok, %Thread{room_id: room_id}} when room_id == entry.room_id -> :ok
      {:ok, %Thread{}} -> {:error, :activity_thread_room_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_message(_persistence, _state, %MessagingActivityEntry{message_id: nil}), do: :ok

  defp validate_message(persistence, state, %MessagingActivityEntry{} = entry) do
    case persistence.get_message(state, entry.message_id) do
      {:ok, message} when message.room_id == entry.room_id and message.thread_id == entry.thread_id -> :ok
      {:ok, _message} -> {:error, :activity_message_scope_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_scope(instance_module, %HistoryScope{instance_module: instance_module, room_ids: room_ids})
       when is_list(room_ids),
       do: :ok

  defp validate_scope(_instance_module, %HistoryScope{}),
    do: {:error, :history_scope_instance_mismatch}

  defp validate_scope(_instance_module, _scope), do: {:error, :history_scope_required}

  defp validate_agent_principal(%Participant{type: :agent}), do: :ok
  defp validate_agent_principal(%Participant{}), do: {:error, :activity_principal_must_be_agent}

  defp require_callbacks(persistence, callbacks) do
    if Enum.all?(callbacks, fn {name, arity} -> function_exported?(persistence, name, arity) end),
      do: :ok,
      else: {:error, :unsupported}
  end
end
