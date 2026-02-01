defmodule JidoMessaging.Runtime do
  @moduledoc """
  Runtime state holder for a JidoMessaging instance.

  Manages adapter initialization and holds per-instance state including
  adapter module and adapter state (e.g., ETS table references).
  """
  use GenServer
  require Logger

  @schema Zoi.struct(
            __MODULE__,
            %{
              instance_module: Zoi.any(),
              adapter: Zoi.any(),
              adapter_state: Zoi.any() |> Zoi.nullish()
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

  @doc "Get the adapter and its state"
  def get_adapter(runtime) do
    GenServer.call(runtime, :get_adapter)
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case adapter.init(adapter_opts) do
      {:ok, adapter_state} ->
        state =
          struct!(__MODULE__, %{
            instance_module: instance_module,
            adapter: adapter,
            adapter_state: adapter_state
          })

        {:ok, state}

      {:error, reason} ->
        {:stop, {:adapter_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_adapter, _from, state) do
    {:reply, {state.adapter, state.adapter_state}, state}
  end
end
