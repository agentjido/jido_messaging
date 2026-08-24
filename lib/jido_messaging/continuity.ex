defmodule Jido.Messaging.Continuity do
  @moduledoc """
  Safe messaging-side references to continuity that Jidoka owns.

  This module stores and resolves correlation records. It does not load a
  Jidoka session, read memory, assemble a prompt, or resume agent work.
  """

  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    HistoryScope,
    JidokaContinuityContext,
    Message,
    Runtime,
    Thread,
    ThreadContinuityLink
  }

  @persistence_callbacks [
    save_thread_continuity_link: 2,
    get_thread_continuity_link: 2
  ]
  @context_options [:before, :after, :limit]
  @status_options [:reason_code, :source_updated_at]

  @doc "Creates or updates the Jidoka continuity link for one messaging thread."
  @spec put(GenServer.server(), map()) :: {:ok, ThreadContinuityLink.t()} | {:error, term()}
  def put(runtime, attrs) when is_map(attrs) do
    link = ThreadContinuityLink.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- ensure_persistence(persistence),
         {:ok, _room} <- persistence.get_room(state, link.room_id),
         {:ok, %Thread{} = thread} <- persistence.get_thread(state, link.thread_id),
         :ok <- ensure_thread_room(thread, link.room_id),
         {:ok, %Participant{} = principal} <- persistence.get_participant(state, link.principal_id),
         :ok <- ensure_agent_principal(principal) do
      persistence.save_thread_continuity_link(state, link)
    end
  rescue
    ArgumentError -> {:error, :invalid_thread_continuity_link}
  end

  def put(_runtime, _attrs), do: {:error, :invalid_thread_continuity_link}

  @doc "Gets a continuity link after the caller supplies an authorized history scope."
  @spec get(module(), GenServer.server(), String.t(), HistoryScope.t()) ::
          {:ok, ThreadContinuityLink.t()} | {:error, term()}
  def get(instance_module, runtime, thread_id, scope)
      when is_atom(instance_module) and is_binary(thread_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- validate_scope(instance_module, scope),
         :ok <- ensure_persistence(persistence),
         {:ok, %ThreadContinuityLink{} = link} <-
           persistence.get_thread_continuity_link(state, thread_id),
         :ok <- validate_scope_room(scope, link.room_id) do
      {:ok, link}
    end
  end

  @doc "Resolves a usable opaque Jidoka reference without calling Jidoka."
  @spec resolve(module(), GenServer.server(), String.t(), HistoryScope.t()) ::
          {:ok, Jido.Messaging.JidokaContinuityRef.t()} | {:error, term()}
  def resolve(instance_module, runtime, thread_id, scope)
      when is_atom(instance_module) and is_binary(thread_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with {:ok, %ThreadContinuityLink{} = link} <- get(instance_module, runtime, thread_id, scope),
         :ok <- ensure_live_link(link),
         :ok <- ensure_active_thread(persistence, state, link) do
      {:ok, link.continuity_ref}
    end
  end

  @doc "Changes continuity availability with an explicit expected revision."
  @spec set_status(GenServer.server(), String.t(), ThreadContinuityLink.status(), pos_integer(), keyword()) ::
          {:ok, ThreadContinuityLink.t()} | {:error, term()}
  def set_status(runtime, thread_id, status, expected_revision, opts \\ [])

  def set_status(runtime, thread_id, status, expected_revision, opts)
      when is_binary(thread_id) and is_atom(status) and is_integer(expected_revision) and
             is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- validate_status_options(opts),
         :ok <- ensure_persistence(persistence),
         {:ok, %ThreadContinuityLink{} = link} <-
           persistence.get_thread_continuity_link(state, thread_id),
         {:ok, updated} <- change_status(link, status, expected_revision, opts) do
      persistence.save_thread_continuity_link(state, updated)
    end
  end

  def set_status(_runtime, _thread_id, _status, _expected_revision, _opts),
    do: {:error, :invalid_continuity_status_change}

  @doc "Clears a continuity link while keeping a durable deletion marker."
  @spec clear(GenServer.server(), String.t(), pos_integer(), keyword()) ::
          {:ok, ThreadContinuityLink.t()} | {:error, term()}
  def clear(runtime, thread_id, expected_revision, opts \\ [])

  def clear(runtime, thread_id, expected_revision, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts = Keyword.put_new(opts, :reason_code, "integration_cleared")
      set_status(runtime, thread_id, :cleared, expected_revision, opts)
    else
      {:error, :invalid_continuity_status_change}
    end
  end

  def clear(_runtime, _thread_id, _expected_revision, _opts),
    do: {:error, :invalid_continuity_status_change}

  @doc "Returns a scoped canonical thread transcript and its opaque Jidoka link."
  @spec context(module(), GenServer.server(), String.t(), HistoryScope.t(), keyword()) ::
          {:ok, JidokaContinuityContext.t()} | {:error, term()}
  def context(instance_module, runtime, thread_id, scope, opts \\ [])

  def context(instance_module, runtime, thread_id, scope, opts)
      when is_atom(instance_module) and is_binary(thread_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with {:ok, message_opts} <- validate_context_options(opts),
         {:ok, %ThreadContinuityLink{} = link} <- get(instance_module, runtime, thread_id, scope),
         :ok <- ensure_live_link(link),
         :ok <- ensure_active_thread(persistence, state, link),
         {:ok, messages} <-
           persistence.get_messages(
             state,
             link.room_id,
             Keyword.put(message_opts, :thread_id, link.thread_id)
           ),
         :ok <- validate_context_messages(messages, link) do
      {:ok, JidokaContinuityContext.new(link, messages)}
    end
  end

  def context(_instance_module, _runtime, _thread_id, _scope, _opts),
    do: {:error, :invalid_continuity_context_options}

  defp ensure_persistence(persistence) do
    if Enum.all?(@persistence_callbacks, fn {name, arity} ->
         function_exported?(persistence, name, arity)
       end) do
      :ok
    else
      {:error, :continuity_persistence_not_supported}
    end
  end

  defp ensure_thread_room(%Thread{room_id: room_id}, room_id), do: :ok
  defp ensure_thread_room(%Thread{}, _room_id), do: {:error, :continuity_thread_room_mismatch}

  defp ensure_agent_principal(%Participant{type: :agent}), do: :ok
  defp ensure_agent_principal(%Participant{}), do: {:error, :continuity_principal_not_agent}

  defp validate_scope(
         instance_module,
         %HistoryScope{instance_module: instance_module, room_ids: room_ids}
       )
       when is_list(room_ids),
       do: :ok

  defp validate_scope(_instance_module, %HistoryScope{}),
    do: {:error, :history_scope_instance_mismatch}

  defp validate_scope(_instance_module, _scope), do: {:error, :history_scope_required}

  defp validate_scope_room(%HistoryScope{room_ids: room_ids}, room_id) do
    if room_id in room_ids, do: :ok, else: {:error, :history_scope_violation}
  end

  defp ensure_active_thread(persistence, state, link) do
    with {:ok, %Thread{} = thread} <- persistence.get_thread(state, link.thread_id),
         :ok <- ensure_thread_room(thread, link.room_id) do
      case thread.status do
        :active -> :ok
        status -> {:error, {:continuity_thread_not_active, status}}
      end
    end
  end

  defp ensure_live_link(%ThreadContinuityLink{} = link) do
    case ThreadContinuityLink.effective_status(link) do
      :active -> :ok
      :unavailable -> {:error, {:continuity_unavailable, link.reason_code}}
      :expired -> {:error, {:continuity_expired, link.reason_code || "reference_expired"}}
      :deleted -> {:error, {:continuity_deleted, link.reason_code}}
      :cleared -> {:error, {:continuity_cleared, link.reason_code}}
    end
  end

  defp change_status(link, status, expected_revision, opts) do
    if link.source_revision == expected_revision do
      source_updated_at = Keyword.get(opts, :source_updated_at, DateTime.utc_now())
      reason_code = Keyword.get(opts, :reason_code, default_reason(status))

      {:ok,
       ThreadContinuityLink.change_status(
         link,
         status,
         expected_revision,
         source_updated_at,
         reason_code
       )}
    else
      {:error, :continuity_revision_conflict}
    end
  rescue
    ArgumentError -> {:error, :invalid_continuity_status_change}
  end

  defp default_reason(:active), do: nil
  defp default_reason(:unavailable), do: "jidoka_unavailable"
  defp default_reason(:expired), do: "jidoka_expired"
  defp default_reason(:deleted), do: "jidoka_deleted"
  defp default_reason(:cleared), do: "integration_cleared"
  defp default_reason(_status), do: nil

  defp validate_status_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys -- @status_options == [] and length(keys) == length(Enum.uniq(keys)) do
        :ok
      else
        {:error, :invalid_continuity_status_change}
      end
    else
      {:error, :invalid_continuity_status_change}
    end
  end

  defp validate_context_options(opts) do
    if Keyword.keyword?(opts) do
      do_validate_context_options(opts)
    else
      {:error, :invalid_continuity_context_options}
    end
  end

  defp do_validate_context_options(opts) do
    keys = Keyword.keys(opts)
    limit = Keyword.get(opts, :limit, 50)
    before_cursor = Keyword.get(opts, :before)
    after_cursor = Keyword.get(opts, :after)

    cond do
      keys -- @context_options != [] or length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_continuity_context_options}

      not is_integer(limit) or limit < 1 or limit > 500 ->
        {:error, :invalid_continuity_context_options}

      not valid_cursor?(before_cursor) or not valid_cursor?(after_cursor) ->
        {:error, :invalid_continuity_context_options}

      not is_nil(before_cursor) and not is_nil(after_cursor) ->
        {:error, :invalid_cursor_options}

      true ->
        {:ok, Keyword.take(opts, @context_options)}
    end
  end

  defp valid_cursor?(nil), do: true
  defp valid_cursor?(cursor), do: is_binary(cursor) and cursor != ""

  defp validate_context_messages(messages, link) when is_list(messages) do
    if Enum.all?(messages, fn
         %Message{room_id: room_id, thread_id: thread_id} ->
           room_id == link.room_id and thread_id == link.thread_id

         _other ->
           false
       end) do
      :ok
    else
      {:error, :continuity_transcript_scope_violation}
    end
  end

  defp validate_context_messages(_messages, _link),
    do: {:error, :continuity_transcript_scope_violation}
end
