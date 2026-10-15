defmodule Jido.Messaging.Runtime do
  @moduledoc """
  Runtime state holder for a Jido.Messaging instance.

  Manages adapter initialization and holds per-instance state including
  adapter module and adapter state (e.g., ETS table references).

  Runtime owns the typed request ledger and bindings created through
  `ensure_binding/4`. Registered external bindings remain owned by their
  creator. Request IDs and results have the lifetime of Runtime; they do not
  expire automatically. See `docs/runtime-ownership.md` for restart limits.
  """
  use GenServer

  @schema Zoi.struct(
            __MODULE__,
            %{
              instance_module: Zoi.any(),
              persistence: Zoi.any(),
              catalog: Zoi.any(),
              request_admissions: Zoi.any(),
              bindings: Zoi.map() |> Zoi.default(%{}),
              persistence_state: Zoi.any() |> Zoi.nullish()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the runtime state for an instance"
  def get_state(runtime) do
    GenServer.call(runtime, :get_state)
  end

  @doc "Returns the configured native catalog for this runtime."
  @spec catalog(atom()) :: {:ok, Jido.Signal.Catalog.t()}
  def catalog(runtime), do: GenServer.call(runtime, :catalog)

  @doc false
  @spec request_table(atom()) :: :ets.table()
  def request_table(runtime), do: GenServer.call(runtime, :request_table)

  @doc false
  @spec resource_owner(atom()) :: Jido.Chat.Resources.owner()
  def resource_owner(runtime), do: GenServer.call(runtime, :resource_owner)

  @doc false
  @spec register_binding(atom(), Jido.Chat.Binding.t()) :: :ok
  def register_binding(runtime, binding), do: GenServer.call(runtime, {:register_binding, binding})

  @doc false
  @spec binding(atom(), String.t()) :: {:ok, Jido.Chat.Binding.t()} | {:error, term()}
  def binding(runtime, key), do: GenServer.call(runtime, {:binding, key})

  @doc false
  @spec ensure_binding(atom(), module(), String.t(), keyword()) :: {:ok, Jido.Chat.Binding.t()} | {:error, term()}
  def ensure_binding(runtime, adapter, id, opts), do: GenServer.call(runtime, {:ensure_binding, adapter, id, opts})

  @doc "Get the persistence adapter and its state."
  def get_persistence(runtime) do
    GenServer.call(runtime, :get_persistence)
  end

  @doc "Get the active persistence adapter capabilities."
  def persistence_capabilities(runtime) do
    {persistence, persistence_state} = get_persistence(runtime)

    if function_exported?(persistence, :capabilities, 1) do
      persistence.capabilities(persistence_state)
    else
      []
    end
  end

  @doc "Check the active persistence adapter connection and schema."
  def persistence_health(runtime) do
    {persistence, persistence_state} = get_persistence(runtime)

    if function_exported?(persistence, :health_check, 1) do
      persistence.health_check(persistence_state)
    else
      {:error, :health_check_not_supported}
    end
  end

  @impl true
  def init(opts) do
    Jido.Messaging.OutboundGateway.Admission.new(Keyword.fetch!(opts, :instance_module))
    instance_module = Keyword.fetch!(opts, :instance_module)
    persistence = Keyword.fetch!(opts, :persistence)

    persistence_opts =
      opts
      |> Keyword.get(:persistence_opts, [])
      |> maybe_add_instance_scope(persistence, instance_module)

    case persistence.init(persistence_opts) do
      {:ok, persistence_state} ->
        state =
          struct!(__MODULE__, %{
            instance_module: instance_module,
            persistence: persistence,
            request_admissions: Jido.Messaging.RequestLedger.new(),
            catalog: Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions() ++ Jido.Messaging.signal_definitions()),
            persistence_state: persistence_state
          })

        {:ok, state}

      {:error, reason} ->
        {:stop, {:persistence_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:request_table, _from, state), do: {:reply, state.request_admissions, state}

  @impl true
  def handle_call(:resource_owner, _from, state) do
    owner = %{
      id: Jido.Messaging.Signal.Identity.instance_source(Atom.to_string(state.instance_module)),
      resources: state.request_admissions
    }

    {:reply, owner, state}
  end

  @impl true
  def handle_call({:register_binding, binding}, _from, state) do
    {:reply, :ok, %{state | bindings: Map.put(state.bindings, binding.id, binding)}}
  end

  @impl true
  def handle_call({:binding, key}, _from, state) do
    binding =
      state.bindings[key] ||
        Enum.find_value(state.bindings, fn {_id, binding} -> if binding.source == key, do: binding end)

    result =
      if binding && :ets.info(binding.resources) != :undefined,
        do: current_binding(state, binding),
        else: {:error, :binding_not_found}

    {:reply, result, state}
  end

  @impl true
  def handle_call({:ensure_binding, adapter, id, opts}, _from, state) do
    case state.bindings[id] do
      %Jido.Chat.Binding{adapter: ^adapter} = binding ->
        cond do
          :ets.info(binding.resources) == :undefined ->
            {:reply, Jido.Chat.Signal.Policy.error(:invalid_binding), state}

          binding_revision_changed?(binding, opts[:bridge_config]) ->
            create_binding(state, adapter, id, opts)

          true ->
            {:reply, {:ok, binding}, state}
        end

      nil ->
        create_binding(state, adapter, id, opts)

      %Jido.Chat.Binding{} = binding ->
        {:reply, {:error, {:bridge_adapter_mismatch, id, binding.adapter, adapter}}, state}
    end
  end

  @impl true
  def handle_call(:catalog, _from, state), do: {:reply, {:ok, state.catalog}, state}

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_persistence, _from, state) do
    {:reply, {state.persistence, state.persistence_state}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if function_exported?(state.persistence, :close, 1) do
      state.persistence.close(state.persistence_state)
    end

    :ok
  end

  defp maybe_add_instance_scope(opts, Jido.Messaging.Persistence.SQLite, instance_module) do
    Keyword.put_new(opts, :instance_id, Atom.to_string(instance_module))
  end

  defp maybe_add_instance_scope(opts, Jido.Messaging.Persistence.Postgres, instance_module) do
    Keyword.put_new(opts, :instance_id, Atom.to_string(instance_module))
  end

  defp maybe_add_instance_scope(opts, _persistence, _instance_module), do: opts

  defp current_binding(state, binding) do
    case read_bridge_config(state, binding.id) do
      {:error, :not_found} ->
        {:ok, binding}

      {:ok, %{enabled: false}} ->
        {:error, :binding_disabled}

      {:ok, config} ->
        if config.adapter_module == binding.adapter and not binding_revision_changed?(binding, config),
          do: {:ok, binding},
          else: {:error, :binding_outdated}

      {:error, _} = error ->
        error
    end
  end

  defp binding_revision_changed?(_binding, nil), do: false

  defp binding_revision_changed?(binding, %Jido.Messaging.BridgeConfig{} = config) do
    case binding.options[:bridge_config] do
      %Jido.Messaging.BridgeConfig{} = previous -> previous.revision != config.revision
      _ -> true
    end
  end

  defp create_binding(state, adapter, id, opts) do
    result =
      with {:ok, resolved} <- binding_options(state, adapter, id, opts) do
        Jido.Chat.bind(
          adapter,
          resolved
          |> Keyword.drop([
            :thread_id,
            :external_thread_id,
            :reply_to_id,
            :cursor,
            :limit,
            :direction,
            :scope,
            :topic_name,
            :request_id,
            :parent_signal,
            :format,
            :fallback_to_dm,
            :security
          ])
          |> Keyword.put(:id, id)
        )
      end

    case result do
      {:ok, binding} ->
        [{Jido.Messaging.RequestStore, store}] = :ets.lookup(state.request_admissions, Jido.Messaging.RequestStore)
        :ok = Jido.Chat.RequestStore.install(binding, {Jido.Messaging.ChatRequestStore, {store, make_ref()}})
        {:reply, {:ok, binding}, %{state | bindings: Map.put(state.bindings, id, binding)}}

      error ->
        {:reply, error, state}
    end
  end

  defp binding_options(state, adapter, id, opts) do
    case read_bridge_config(state, id) do
      {:ok, %Jido.Messaging.BridgeConfig{adapter_module: ^adapter} = config} ->
        Jido.Messaging.SecretResolver.adapter_opts_for_config(state.instance_module, config, :configure, opts)

      {:ok, config} ->
        {:error, {:bridge_adapter_mismatch, id, config.adapter_module, adapter}}

      {:error, :not_found} ->
        {:ok, opts}

      {:error, _} = error ->
        error
    end
  end

  defp read_bridge_config(state, id) do
    case state.persistence.get_bridge_config(state.persistence_state, id) do
      {:ok, %Jido.Messaging.BridgeConfig{id: ^id} = config} -> {:ok, config}
      {:error, _} = error -> error
      _ -> {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end
end
