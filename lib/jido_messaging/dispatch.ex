defmodule Jido.Messaging.Dispatch do
  @moduledoc "Native Catalog validation and ordered Dispatch to one instance Bus."

  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.Runtime
  alias Jido.Messaging.Supervisor, as: MessagingSupervisor
  alias Jido.Signal.{Catalog, Dispatch}

  @type emit_opts :: keyword()

  @doc "Publishes a registered fact or result. This path cannot execute a request."
  @spec emit(module() | nil, Jido.Signal.t(), emit_opts()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def emit(instance, signal, opts \\ [])

  def emit(instance, %Jido.Signal{} = signal, opts) do
    with {:ok, catalog} <- catalog(instance),
         {:ok, ^signal} <- Catalog.validate(catalog, signal),
         {:ok, ^signal} <- Policy.validate(signal),
         :ok <- observable(signal) do
      telemetry(opts)

      case dispatch(instance, signal) do
        :ok -> {:ok, signal}
        {:error, _} = error -> error
      end
    end
  end

  def emit(_instance, _signal, _opts), do: Policy.error(:invalid_request)

  @doc "Subscribes to a native type path and optional exact source/subject selector."
  @spec subscribe(module(), String.t(), keyword()) :: {:ok, Jido.Signal.Bus.subscription_id()} | {:error, term()}
  def subscribe(instance, path, opts \\ []),
    do: Jido.Signal.Bus.subscribe(MessagingSupervisor.signal_bus_name(instance), path, opts)

  @doc "Removes an ordinary instance Bus subscription."
  @spec unsubscribe(module(), Jido.Signal.Bus.subscription_id(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(instance, id, opts \\ []),
    do: Jido.Signal.Bus.unsubscribe(MessagingSupervisor.signal_bus_name(instance), id, opts)

  defp catalog(nil), do: {:ok, Catalog.new!(Jido.Chat.signal_definitions() ++ Jido.Messaging.signal_definitions())}
  defp catalog(instance), do: Runtime.catalog(instance.__jido_messaging__(:runtime))

  defp observable(signal) do
    definition =
      Enum.find(Jido.Chat.signal_definitions() ++ Jido.Messaging.signal_definitions(), &(&1.type() == signal.type))

    if definition.__signal_kind__() in [:fact, :result], do: :ok, else: Policy.error(:invalid_request)
  end

  defp dispatch(nil, _signal), do: :ok

  defp dispatch(instance, signal),
    do: Dispatch.dispatch(signal, {:bus, target: MessagingSupervisor.signal_bus_name(instance)})

  defp telemetry(opts) do
    if event = opts[:telemetry_event] do
      :telemetry.execute(
        event,
        Keyword.get(opts, :telemetry_measurements, %{timestamp: DateTime.utc_now()}),
        Keyword.get(opts, :telemetry_metadata, %{})
      )
    end
  end
end
