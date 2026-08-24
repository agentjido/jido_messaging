defmodule Jido.Messaging.Runtime do
  @moduledoc """
  Runtime state holder for a Jido.Messaging instance.

  Manages adapter initialization and holds per-instance state including
  adapter module and adapter state (e.g., ETS table references).
  """
  use GenServer

  @schema Zoi.struct(
            __MODULE__,
            %{
              instance_module: Zoi.any(),
              persistence: Zoi.any(),
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
            persistence_state: persistence_state
          })

        {:ok, state}

      {:error, reason} ->
        {:stop, {:persistence_init_failed, reason}}
    end
  end

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
end
