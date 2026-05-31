defmodule Jido.Messaging.Presence do
  @moduledoc """
  Phoenix Presence adapter for `Jido.Messaging` participant activity signals.

  `jido_messaging` does not own realtime transport state, but Phoenix Presence
  is the canonical way Phoenix applications track connected users. This adapter
  keeps the reusable mechanics in one place:

  * session heartbeats and TTL pruning
  * Phoenix Presence `track/update/untrack` calls
  * normalized `jido.messaging.*` participant signals

  Applications still own product policy and read models. A small app module can
  wrap the adapter with:

      defmodule MyApp.Presence do
        use Jido.Messaging.Presence,
          messaging: MyApp.Messaging,
          presence: MyAppWeb.Presence,
          topic: "my_app:presence",
          source: "my_app.presence"
      end
  """

  @default_heartbeat_ms 15_000
  @default_prune_ms 5_000

  require Logger

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer

      @jido_messaging_presence_opts opts

      def child_spec(init_opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_opts]},
          type: :worker
        }
      end

      def start_link(init_opts \\ []) do
        GenServer.start_link(__MODULE__, init_opts, name: __MODULE__)
      end

      def heartbeat_interval_ms do
        Jido.Messaging.Presence.heartbeat_interval_ms(__presence_config__())
      end

      def touch(participant_id, room_id, opts \\ []) do
        Jido.Messaging.Presence.touch(__MODULE__, participant_id, room_id, opts)
      end

      def mark_left(participant_id, opts \\ []) do
        Jido.Messaging.Presence.mark_left(__MODULE__, participant_id, opts)
      end

      def online?(participant_id) do
        Jido.Messaging.Presence.online?(__MODULE__, participant_id)
      end

      def online_user_ids do
        Jido.Messaging.Presence.online_user_ids(__MODULE__)
      end

      def snapshot do
        Jido.Messaging.Presence.snapshot(__MODULE__)
      end

      def reset do
        Jido.Messaging.Presence.reset(__MODULE__)
      end

      def __presence_config__ do
        Jido.Messaging.Presence.config(__MODULE__, @jido_messaging_presence_opts)
      end

      @impl true
      def init(init_opts) do
        Jido.Messaging.Presence.init(__presence_config__(), init_opts)
      end

      @impl true
      def handle_call(message, from, state) do
        Jido.Messaging.Presence.handle_call(message, from, state)
      end

      @impl true
      def handle_info(message, state) do
        Jido.Messaging.Presence.handle_info(message, state)
      end
    end
  end

  @doc false
  def config(adapter_module, opts) do
    %{
      adapter: adapter_module,
      messaging: Keyword.fetch!(opts, :messaging),
      presence: Keyword.fetch!(opts, :presence),
      topic: Keyword.fetch!(opts, :topic),
      source: Keyword.get(opts, :source, "jido_messaging.presence"),
      otp_app: Keyword.get(opts, :otp_app),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @default_heartbeat_ms),
      ttl_ms: Keyword.get(opts, :ttl_ms),
      prune_ms: Keyword.get(opts, :prune_ms, @default_prune_ms),
      notify: Keyword.get(opts, :notify),
      signal_opts: opts |> Keyword.get(:signal_opts, []) |> normalize_opts()
    }
  end

  @doc false
  def heartbeat_interval_ms(config) do
    config
    |> app_env(:presence_heartbeat_ms, config.heartbeat_ms)
    |> normalize_milliseconds(@default_heartbeat_ms, allow_zero?: false)
  end

  def touch(adapter_module, participant_id, room_id, opts) when is_atom(adapter_module) do
    with {:ok, participant_id} <- normalize_required_id(participant_id, :missing_participant),
         {:ok, room_id} <- normalize_required_id(room_id, :missing_room) do
      call(adapter_module, {:touch, participant_id, room_id, normalize_opts(opts)})
    end
  end

  @doc false
  def mark_left(adapter_module, participant_id, opts) when is_atom(adapter_module) do
    with {:ok, participant_id} <- normalize_required_id(participant_id, :missing_participant) do
      call(adapter_module, {:mark_left, participant_id, normalize_opts(opts)})
    end
  end

  @doc false
  def online?(adapter_module, participant_id) when is_atom(adapter_module) do
    case normalize_optional_id(participant_id) do
      nil -> false
      participant_id -> participant_id in online_user_ids(adapter_module)
    end
  end

  @doc false
  def online_user_ids(adapter_module) when is_atom(adapter_module) do
    case call(adapter_module, :online_user_ids) do
      {:ok, user_ids} -> user_ids
      {:error, :not_started} -> []
    end
  end

  @doc false
  def snapshot(adapter_module) when is_atom(adapter_module) do
    case call(adapter_module, :snapshot) do
      {:ok, snapshot} -> snapshot
      {:error, :not_started} -> empty_payload()
    end
  end

  @doc false
  def reset(adapter_module) when is_atom(adapter_module) do
    call(adapter_module, :reset)
  end

  @doc false
  def init(config, init_opts) do
    config = merge_runtime_config(config, init_opts)
    validate_config!(config)
    schedule_prune(config)

    {:ok, %{config: config, participants: %{}}}
  end

  @doc false
  def handle_call({:touch, participant_id, room_id, opts}, _from, state) do
    opts = normalize_opts(opts)
    now = System.system_time(:millisecond)
    session_id = normalize_session_id(participant_id, Keyword.get(opts, :session_id))
    current = participant_state(state, participant_id, now)
    existing_session = Map.get(current.sessions, session_id)

    meta = session_meta(state.config, participant_id, room_id, session_id, current, existing_session, opts, now)

    case track_or_update(state.config, existing_session, meta) do
      :ok ->
        sessions = Map.put(current.sessions, session_id, meta)
        participants = Map.put(state.participants, participant_id, %{current | sessions: sessions})
        state = %{state | participants: participants}
        signals = touch_signals(state.config, participant_id, room_id, existing_session, meta, current)

        {:reply, {:ok, payload(state), signals}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_left, participant_id, opts}, _from, state) do
    opts = normalize_opts(opts)
    {reply, state} = leave_participant(state, participant_id, opts)
    {:reply, reply, state}
  end

  def handle_call(:online_user_ids, _from, state) do
    {:reply, {:ok, online_user_ids_from_state(state)}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, payload(state)}, state}
  end

  def handle_call(:reset, _from, state) do
    state.participants
    |> all_sessions()
    |> Enum.each(&untrack(state.config, &1))

    state = %{state | participants: %{}}
    {:reply, {:ok, payload(state)}, state}
  end

  @doc false
  def handle_info(:prune, state) do
    now = System.system_time(:millisecond)

    {participants, expired_sessions} =
      Enum.reduce(state.participants, {%{}, []}, fn {participant_id, participant}, {active_acc, expired_acc} ->
        {expired, active} =
          participant.sessions
          |> Map.values()
          |> Enum.split_with(&(&1.expires_at <= now))

        Enum.each(expired, &untrack(state.config, &1))

        active_sessions = Map.new(active, &{&1.session_id, &1})

        cond do
          expired == [] ->
            {Map.put(active_acc, participant_id, participant), expired_acc}

          active_sessions == %{} ->
            {active_acc, expired ++ expired_acc}

          true ->
            participant = %{participant | sessions: active_sessions}
            {Map.put(active_acc, participant_id, participant), expired ++ expired_acc}
        end
      end)

    state = %{state | participants: participants}

    signals =
      prune_signals(state.config, Enum.reverse(expired_sessions), state.participants)

    notify(state, :prune, signals)
    schedule_prune(state.config)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call(adapter_module, message) do
    case Process.whereis(adapter_module) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(adapter_module, message)
    end
  end

  defp merge_runtime_config(config, init_opts) do
    init_opts = normalize_opts(init_opts)

    Enum.reduce(init_opts, config, fn
      {key, value}, acc when key in [:heartbeat_ms, :ttl_ms, :prune_ms, :notify, :signal_opts] ->
        value = if key == :signal_opts, do: normalize_opts(value), else: value
        Map.put(acc, key, value)

      _other, acc ->
        acc
    end)
  end

  defp participant_state(state, participant_id, now) do
    Map.get(state.participants, participant_id, %{online_at: now, sessions: %{}})
  end

  defp validate_config!(config) do
    ensure_module!(config.messaging, :messaging)
    ensure_module!(config.presence, :presence)
    ensure_exported!(config.messaging, :participant_joined, 3)
    ensure_exported!(config.messaging, :participant_left, 3)
    ensure_exported!(config.messaging, :participant_presence_changed, 5)
    ensure_exported!(config.presence, :track, 4)
    ensure_exported!(config.presence, :update, 4)
    ensure_exported!(config.presence, :untrack, 3)

    unless is_binary(topic(config)) do
      raise ArgumentError, "expected :topic to resolve to a string"
    end

    config
  end

  defp ensure_module!(module, key) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      raise ArgumentError, "expected :#{key} to be a loaded module, got: #{inspect(module)}"
    end
  end

  defp ensure_module!(value, key) do
    raise ArgumentError, "expected :#{key} to be a module, got: #{inspect(value)}"
  end

  defp ensure_exported!(module, function, arity) do
    unless function_exported?(module, function, arity) do
      raise ArgumentError, "expected #{inspect(module)} to export #{function}/#{arity}"
    end
  end

  defp session_meta(config, participant_id, room_id, session_id, participant, existing_session, opts, now) do
    %{
      participant_id: participant_id,
      room_id: room_id,
      session_id: session_id,
      track_pid: track_pid(opts),
      online_at: (existing_session && existing_session.online_at) || participant.online_at || now,
      last_seen_at: now,
      expires_at: now + session_ttl_ms(config, opts),
      source: config.source,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp touch_signals(config, participant_id, room_id, nil, meta, current) do
    was_online? = map_size(current.sessions) > 0
    room_already_occupied? = room_occupied?(current, room_id)

    cond do
      not was_online? ->
        [
          joined_signal(config, room_id, participant_id, meta),
          presence_changed_signal(config, room_id, participant_id, :offline, :online, meta)
        ]

      room_already_occupied? ->
        []

      true ->
        [joined_signal(config, room_id, participant_id, meta)]
    end
    |> successful_signals()
  end

  defp touch_signals(config, participant_id, room_id, %{room_id: previous_room_id} = previous, meta, current)
       when previous_room_id != room_id do
    [
      unless(room_occupied?(current, previous_room_id, previous.session_id),
        do: left_signal(config, previous_room_id, participant_id, previous, :room_changed)
      ),
      unless(room_occupied?(current, room_id, previous.session_id),
        do: joined_signal(config, room_id, participant_id, meta)
      )
    ]
    |> successful_signals()
  end

  defp touch_signals(_config, _participant_id, _room_id, _previous, _meta, _current), do: []

  defp prune_signals(config, expired_sessions, active_participants) do
    (room_left_signals(config, expired_sessions, active_participants, :expired) ++
       offline_signals(config, expired_sessions, active_participants))
    |> successful_signals()
  end

  defp leave_participant(state, participant_id, opts) do
    case Map.get(state.participants, participant_id) do
      nil ->
        {{:ok, payload(state), []}, state}

      participant ->
        session_id = normalize_optional_id(Keyword.get(opts, :session_id))
        {removed, remaining_sessions} = pop_sessions(participant.sessions, session_id)

        Enum.each(removed, &untrack(state.config, &1))

        participants =
          if remaining_sessions == %{} do
            Map.delete(state.participants, participant_id)
          else
            Map.put(state.participants, participant_id, %{participant | sessions: remaining_sessions})
          end

        state = %{state | participants: participants}
        reason = Keyword.get(opts, :reason, :manual)
        signals = leave_signals(state.config, removed, state.participants, reason)

        notify(state, :leave, signals)

        {{:ok, payload(state), signals}, state}
    end
  end

  defp pop_sessions(sessions, nil), do: {Map.values(sessions), %{}}

  defp pop_sessions(sessions, session_id) do
    case Map.pop(sessions, session_id) do
      {nil, remaining} -> {[], remaining}
      {session, remaining} -> {[session], remaining}
    end
  end

  defp leave_signals(_config, [], _active_participants, _reason), do: []

  defp leave_signals(config, removed, active_participants, reason) do
    (room_left_signals(config, removed, active_participants, reason) ++
       offline_signals(config, removed, active_participants))
    |> successful_signals()
  end

  defp joined_signal(config, room_id, participant_id, meta) do
    apply(config.messaging, :participant_joined, [
      room_id,
      participant_id,
      event_opts(config, room_id, meta, presence: :online)
    ])
  end

  defp left_signal(config, room_id, participant_id, meta, reason) do
    apply(config.messaging, :participant_left, [
      room_id,
      participant_id,
      event_opts(config, room_id, meta, reason: reason)
    ])
  end

  defp presence_changed_signal(config, room_id, participant_id, from, to, meta) do
    apply(config.messaging, :participant_presence_changed, [
      room_id,
      participant_id,
      from,
      to,
      event_opts(config, room_id, meta)
    ])
  end

  defp event_opts(config, room_id, meta, extra \\ []) do
    config.signal_opts
    |> Keyword.merge(extra)
    |> Keyword.put_new(:external_room_id, room_id)
    |> Keyword.put(:session_id, meta.session_id)
    |> Keyword.put(:source, config.source)
    |> maybe_put_opt(:metadata, meta.metadata)
  end

  defp maybe_put_opt(opts, _key, value) when value in [nil, %{}], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp room_left_signals(config, removed_sessions, active_participants, reason) do
    removed_sessions
    |> Enum.group_by(&{&1.participant_id, &1.room_id})
    |> Enum.map(fn {{participant_id, room_id}, sessions} ->
      unless participant_in_room?(active_participants, participant_id, room_id) do
        left_signal(config, room_id, participant_id, List.last(sessions), reason)
      end
    end)
  end

  defp offline_signals(config, removed_sessions, active_participants) do
    removed_sessions
    |> Enum.group_by(& &1.participant_id)
    |> Enum.map(fn {participant_id, sessions} ->
      unless Map.has_key?(active_participants, participant_id) do
        meta = List.last(sessions)
        presence_changed_signal(config, meta.room_id, participant_id, :online, :offline, meta)
      end
    end)
  end

  defp participant_in_room?(participants, participant_id, room_id) do
    participants
    |> Map.get(participant_id, %{sessions: %{}})
    |> room_occupied?(room_id)
  end

  defp room_occupied?(participant, room_id, except_session_id \\ nil) do
    participant.sessions
    |> Map.values()
    |> Enum.any?(fn meta ->
      meta.room_id == room_id and meta.session_id != except_session_id
    end)
  end

  defp successful_signals(results) do
    Enum.flat_map(results, fn
      {:ok, signal} -> [signal]
      {:error, _reason} -> []
      nil -> []
    end)
  end

  defp track_or_update(config, nil, meta), do: track(config, meta)
  defp track_or_update(config, _existing_session, meta), do: update(config, meta)

  defp track(config, meta) do
    case apply(config.presence, :track, [meta.track_pid, topic(config), presence_key(meta), meta]) do
      {:ok, _ref} -> :ok
      :ok -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> update(config, meta)
      {:error, reason} -> {:error, reason}
    end
  end

  defp update(config, meta) do
    case apply(config.presence, :update, [meta.track_pid, topic(config), presence_key(meta), meta]) do
      {:ok, _ref} -> :ok
      :ok -> :ok
      {:error, :not_found} -> track(config, meta)
      {:error, reason} -> {:error, reason}
    end
  end

  defp untrack(config, meta) do
    apply(config.presence, :untrack, [meta.track_pid || self(), topic(config), presence_key(meta)])
  end

  defp notify(_state, _event, []), do: :ok

  defp notify(state, event, signals) do
    try do
      case state.config.notify do
        nil ->
          :ok

        {module, function, args} ->
          apply(module, function, [event, payload(state), signals | List.wrap(args)])

        {module, function} ->
          apply(module, function, [event, payload(state), signals])

        function when is_function(function, 3) ->
          function.(event, payload(state), signals)

        function when is_function(function, 2) ->
          function.(payload(state), signals)

        other ->
          Logger.debug("[Jido.Messaging.Presence] Ignoring invalid notify callback: #{inspect(other)}")
          :ok
      end
    rescue
      exception ->
        Logger.debug(
          "[Jido.Messaging.Presence] Notify callback failed: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )

        :ok
    catch
      kind, reason ->
        Logger.debug("[Jido.Messaging.Presence] Notify callback failed: #{inspect({kind, reason})}")
        :ok
    end
  end

  defp payload(state), do: %{online_user_ids: online_user_ids_from_state(state)}
  defp empty_payload, do: %{online_user_ids: []}

  defp online_user_ids_from_state(state) do
    state.participants
    |> Enum.filter(fn {_participant_id, participant} -> map_size(participant.sessions) > 0 end)
    |> Enum.map(fn {participant_id, _participant} -> participant_id end)
    |> Enum.sort()
  end

  defp all_sessions(participants) do
    participants
    |> Map.values()
    |> Enum.flat_map(&Map.values(&1.sessions))
  end

  defp presence_key(meta), do: meta.session_id

  defp topic(%{topic: {module, function, args}}), do: apply(module, function, args)
  defp topic(%{topic: topic}) when is_binary(topic), do: topic

  defp app_env(%{otp_app: nil}, _key, default), do: default

  defp app_env(%{otp_app: otp_app}, key, default) do
    case Application.get_env(otp_app, key, default) do
      nil -> default
      value -> value
    end
  end

  defp session_ttl_ms(config, opts) do
    ttl_ms =
      Keyword.get(opts, :ttl_ms) ||
        app_env(config, :presence_ttl_ms, config.ttl_ms || heartbeat_interval_ms(config) * 3)

    normalize_milliseconds(ttl_ms, heartbeat_interval_ms(config) * 3, allow_zero?: true)
  end

  defp prune_ms(config) do
    config
    |> app_env(:presence_prune_ms, config.prune_ms)
    |> normalize_milliseconds(@default_prune_ms, allow_zero?: false)
  end

  defp schedule_prune(config) do
    Process.send_after(self(), :prune, prune_ms(config))
  end

  defp normalize_required_id(value, error) do
    case normalize_optional_id(value) do
      nil -> {:error, error}
      id -> {:ok, id}
    end
  end

  defp normalize_optional_id(nil), do: nil

  defp normalize_optional_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp normalize_optional_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_id(_value), do: nil

  defp normalize_opts(opts) when is_list(opts) do
    Enum.flat_map(opts, &normalize_option_pair/1)
  end

  defp normalize_opts(opts) when is_map(opts) do
    Enum.flat_map(opts, &normalize_option_pair/1)
  end

  defp normalize_opts(_opts), do: []

  defp normalize_option_pair({key, value}) do
    case normalize_option_key(key) do
      nil -> []
      key -> [{key, value}]
    end
  end

  defp normalize_option_pair(_other), do: []

  defp normalize_option_key(key) when is_atom(key), do: key
  defp normalize_option_key("adapter_event_type"), do: :adapter_event_type
  defp normalize_option_key("bridge_id"), do: :bridge_id
  defp normalize_option_key("causation_id"), do: :causation_id
  defp normalize_option_key("channel"), do: :channel
  defp normalize_option_key("channel_type"), do: :channel_type
  defp normalize_option_key("chat_type"), do: :chat_type
  defp normalize_option_key("correlation_id"), do: :correlation_id
  defp normalize_option_key("dataschema"), do: :dataschema
  defp normalize_option_key("delivery_external_room_id"), do: :delivery_external_room_id
  defp normalize_option_key("external_message_id"), do: :external_message_id
  defp normalize_option_key("external_room_id"), do: :external_room_id
  defp normalize_option_key("external_thread_id"), do: :external_thread_id
  defp normalize_option_key("heartbeat_ms"), do: :heartbeat_ms
  defp normalize_option_key("instance_id"), do: :instance_id
  defp normalize_option_key("message_id"), do: :message_id
  defp normalize_option_key("metadata"), do: :metadata
  defp normalize_option_key("notify"), do: :notify
  defp normalize_option_key("payload_kind"), do: :payload_kind
  defp normalize_option_key("presence_pid"), do: :presence_pid
  defp normalize_option_key("prune_ms"), do: :prune_ms
  defp normalize_option_key("reason"), do: :reason
  defp normalize_option_key("session_id"), do: :session_id
  defp normalize_option_key("signal_opts"), do: :signal_opts
  defp normalize_option_key("target_kind"), do: :target_kind
  defp normalize_option_key("thread_id"), do: :thread_id
  defp normalize_option_key("track_pid"), do: :track_pid
  defp normalize_option_key("ttl_ms"), do: :ttl_ms
  defp normalize_option_key(_key), do: nil

  defp normalize_milliseconds(value, default, opts) when is_integer(value) do
    cond do
      value > 0 -> value
      value == 0 and Keyword.get(opts, :allow_zero?, false) -> 0
      true -> default
    end
  end

  defp normalize_milliseconds(value, default, opts) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} -> normalize_milliseconds(milliseconds, default, opts)
      _other -> default
    end
  end

  defp normalize_milliseconds(_value, default, _opts), do: default

  defp track_pid(opts) do
    pid = Keyword.get(opts, :presence_pid) || Keyword.get(opts, :track_pid)

    if is_pid(pid), do: pid, else: self()
  end

  defp normalize_session_id(participant_id, nil), do: "presence:#{participant_id}"

  defp normalize_session_id(participant_id, session_id) do
    normalize_optional_id(session_id) || "presence:#{participant_id}"
  end
end
