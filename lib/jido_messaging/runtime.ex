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

  defp maybe_add_instance_scope(opts, Jido.Messaging.Persistence.SQLite, instance_module) do
    Keyword.put_new(opts, :instance_id, Atom.to_string(instance_module))
  end

  defp maybe_add_instance_scope(opts, _persistence, _instance_module), do: opts
end
