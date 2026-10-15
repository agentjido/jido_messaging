defmodule Jido.Messaging.History.Transcript do
  @moduledoc false

  alias Jido.Messaging.{Identity, Runtime}

  @doc false
  @spec participant_transcript(module(), atom(), String.t(), term(), keyword()) ::
          {:ok, [Jido.Messaging.TranscriptEntry.t()]} | {:error, term()}
  def participant_transcript(instance_module, runtime, participant_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(participant_id) and is_list(opts) do
    transcript_read(fn ->
      with :ok <- validate_history_scope(instance_module, scope),
           {persistence, persistence_state} <- Runtime.get_persistence(runtime),
           {:ok, participant} <- persistence.get_participant(persistence_state, participant_id),
           {:ok, messages} <-
             persistence.get_participant_messages(persistence_state, participant_id, scope.room_ids, opts) do
        entries =
          Enum.map(
            messages,
            &build_transcript_entry(
              instance_module,
              persistence,
              persistence_state,
              participant,
              &1
            )
          )

        {:ok, entries}
      end
    end)
  end

  @doc false
  @spec search_transcript(module(), String.t(), term(), keyword()) ::
          {:ok, [Jido.Messaging.TranscriptEntry.t()]} | {:error, term()}
  def search_transcript(instance_module, query, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(query) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection) do
      context = %{instance_module: instance_module, scope: scope}

      with {:ok, entries} <-
             projection_call(fn -> projection.search(query, context, Keyword.delete(opts, :projection)) end, :search),
           :ok <- validate_projection_results(entries, instance_module, scope) do
        {:ok, entries}
      end
    end
  end

  @doc false
  @spec upsert_transcript_search(module(), atom(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def upsert_transcript_search(instance_module, runtime, message_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection),
         {persistence, persistence_state} <- Runtime.get_persistence(runtime),
         {:ok, message} <- persistence.get_message(persistence_state, message_id),
         :ok <- validate_history_room(scope, message.room_id),
         {:ok, participant} <- persistence.get_participant(persistence_state, message.sender_id) do
      entry =
        build_transcript_entry(
          instance_module,
          persistence,
          persistence_state,
          participant,
          message
        )

      context = %{instance_module: instance_module, scope: scope}
      projection_call(fn -> projection.upsert(entry, context, Keyword.delete(opts, :projection)) end, :write)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_transcript_result}
    end
  rescue
    _ -> {:error, :transcript_read_failed}
  catch
    _, _ -> {:error, :transcript_read_failed}
  end

  @doc false
  @spec delete_transcript_search(module(), String.t(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def delete_transcript_search(instance_module, message_id, room_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(room_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         :ok <- validate_history_room(scope, room_id),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection) do
      context = %{instance_module: instance_module, scope: scope}
      projection_call(fn -> projection.delete(message_id, context, Keyword.delete(opts, :projection)) end, :write)
    end
  end

  @doc false
  @spec rebuild_transcript_search(module(), atom(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def rebuild_transcript_search(instance_module, runtime, participant_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(participant_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection),
         {:ok, entries} <- collect_transcript(instance_module, runtime, participant_id, scope, opts) do
      context = %{instance_module: instance_module, scope: scope}

      projection_call(
        fn -> projection.rebuild(entries, context, Keyword.drop(opts, [:projection, :batch_size])) end,
        :write
      )
    end
  end

  defp build_transcript_entry(
         instance_module,
         persistence,
         persistence_state,
         participant,
         message
       ) do
    authorship = Identity.authorship_for_message(message, participant)
    binding = Identity.binding_for_message(persistence, persistence_state, message, authorship)

    Jido.Messaging.TranscriptEntry.new(instance_module, participant, message,
      authorship: authorship,
      external_identity_binding: binding
    )
  end

  defp validate_history_scope(
         instance_module,
         %Jido.Messaging.HistoryScope{instance_module: instance_module, room_ids: room_ids, metadata: metadata}
       ) do
    case Jido.Messaging.HistoryScope.new(instance_module, room_ids, metadata) do
      {:ok, _scope} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_history_scope(_instance_module, %Jido.Messaging.HistoryScope{}) do
    {:error, :history_scope_instance_mismatch}
  end

  defp validate_history_scope(_instance_module, _scope), do: {:error, :history_scope_required}

  defp validate_history_room(scope, room_id) do
    if room_id in scope.room_ids, do: :ok, else: {:error, :history_scope_violation}
  end

  defp search_projection(instance_module, opts) do
    projection =
      Keyword.get(opts, :projection) ||
        Application.get_env(instance_module, :search_projection) ||
        Application.get_env(:jido_messaging, :search_projection)

    if is_atom(projection) and not is_nil(projection) do
      {:ok, projection}
    else
      {:error, :search_projection_not_configured}
    end
  end

  defp validate_projection(projection) do
    callbacks = [upsert: 3, delete: 3, search: 3, rebuild: 3]

    if Code.ensure_loaded?(projection) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(projection, name, arity) end) do
      :ok
    else
      {:error, :invalid_search_projection}
    end
  end

  defp projection_call(callback, operation) do
    case {operation, callback.()} do
      {:search, {:ok, entries}} -> {:ok, entries}
      {:write, :ok} -> :ok
      {_, {:error, _} = error} -> error
      _ -> {:error, :invalid_search_projection_result}
    end
  rescue
    _ -> {:error, :search_projection_failed}
  catch
    _, _ -> {:error, :search_projection_failed}
  end

  defp transcript_read(callback) do
    case callback.() do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      {:error, _} = error -> error
      _ -> {:error, :invalid_transcript_result}
    end
  rescue
    _ -> {:error, :transcript_read_failed}
  catch
    _, _ -> {:error, :transcript_read_failed}
  end

  defp validate_projection_results(entries, instance_module, scope) when is_list(entries) do
    allowed_rooms = MapSet.new(scope.room_ids)
    {persistence, state} = Runtime.get_persistence(instance_module.__jido_messaging__(:runtime))

    if Enum.all?(entries, fn
         %Jido.Messaging.TranscriptEntry{instance_module: ^instance_module, room_id: room_id} = entry ->
           MapSet.member?(allowed_rooms, room_id) and
             projection_entry_consistent?(entry, instance_module, persistence, state)

         _other ->
           false
       end) do
      :ok
    else
      {:error, :search_projection_scope_violation}
    end
  end

  defp validate_projection_results(_entries, _instance_module, _scope) do
    {:error, :invalid_search_projection_result}
  end

  defp projection_entry_consistent?(%Jido.Messaging.TranscriptEntry{} = entry, instance, persistence, state) do
    with {:ok, message} <- persistence.get_message(state, entry.canonical_message_id),
         {:ok, participant} <- persistence.get_participant(state, message.sender_id) do
      canonical = build_transcript_entry(instance, persistence, state, participant, message)

      Map.drop(entry, [:authorship]) == Map.drop(canonical, [:authorship]) and
        projection_authorship_consistent?(entry.authorship, canonical.authorship, message)
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp projection_authorship_consistent?(
         %Jido.Messaging.Authorship{} = entry,
         %Jido.Messaging.Authorship{} = canonical,
         message
       ) do
    stored_authorship = Map.get(message.metadata, :authorship) || Map.get(message.metadata, "authorship")

    if is_nil(message.inserted_at) and is_nil(message.updated_at) and is_nil(stored_authorship),
      do: Map.delete(entry, :asserted_at) == Map.delete(canonical, :asserted_at),
      else: entry == canonical
  end

  defp projection_authorship_consistent?(_entry, _canonical, _message), do: false

  defp collect_transcript(instance_module, runtime, participant_id, scope, opts) do
    batch_size = opts |> Keyword.get(:batch_size, 500) |> normalize_transcript_batch_size()

    page_opts =
      opts
      |> Keyword.drop([:projection, :batch_size, :before, :after])
      |> Keyword.put(:limit, batch_size)

    with {:ok, latest} <- participant_transcript(instance_module, runtime, participant_id, scope, page_opts) do
      collect_older_transcript(instance_module, runtime, participant_id, scope, page_opts, latest)
    end
  end

  defp collect_older_transcript(_instance_module, _runtime, _participant_id, _scope, _opts, []), do: {:ok, []}

  defp collect_older_transcript(instance_module, runtime, participant_id, scope, opts, entries) do
    before = entries |> List.first() |> Map.fetch!(:canonical_message_id)

    case participant_transcript(instance_module, runtime, participant_id, scope, Keyword.put(opts, :before, before)) do
      {:ok, []} ->
        {:ok, entries}

      {:ok, older} ->
        with {:ok, all_older} <-
               collect_older_transcript(instance_module, runtime, participant_id, scope, opts, older) do
          {:ok, all_older ++ entries}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_transcript_batch_size(value) when is_integer(value) and value > 0, do: min(value, 1_000)
  defp normalize_transcript_batch_size(_value), do: 500
end
