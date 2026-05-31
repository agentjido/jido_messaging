defmodule Jido.Messaging.Dispatch do
  @moduledoc """
  Dispatches `Jido.Messaging` signals through Jido Signal primitives.

  The canonical path is `Jido.Signal.Dispatch` to the instance Signal Bus. A
  legacy room PubSub mirror is still supported for older LiveView/demo code, but
  new code should subscribe to Signal Bus paths such as
  `"jido.messaging.room.**"`.
  """

  require Logger

  alias Jido.Messaging.Supervisor, as: MessagingSupervisor
  alias Jido.Signal.Dispatch, as: SignalDispatch

  @type emit_opts :: [
          telemetry_event: [atom()] | nil,
          telemetry_metadata: map(),
          telemetry_measurements: map(),
          room_id: String.t() | nil,
          legacy_event: term() | nil
        ]

  @spec emit(module() | nil, Jido.Signal.t(), emit_opts()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def emit(instance_module, %Jido.Signal{} = signal, opts \\ []) do
    maybe_emit_telemetry(signal, opts)

    result =
      case dispatch_signal(instance_module, signal) do
        :ok ->
          {:ok, signal}

        {:error, reason} = error ->
          Logger.debug("[Jido.Messaging.Dispatch] Failed to dispatch #{signal.type}: #{inspect(reason)}")
          error
      end

    maybe_emit_legacy_pubsub(instance_module, signal, opts)

    result
  end

  @spec subscribe(module(), String.t(), keyword()) ::
          {:ok, Jido.Signal.Bus.subscription_id()} | {:error, term()}
  def subscribe(instance_module, path, opts \\ []) when is_atom(instance_module) and is_binary(path) do
    instance_module
    |> MessagingSupervisor.signal_bus_name()
    |> Jido.Signal.Bus.subscribe(path, opts)
  end

  @spec unsubscribe(module(), Jido.Signal.Bus.subscription_id(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(instance_module, subscription_id, opts \\ []) when is_atom(instance_module) do
    instance_module
    |> MessagingSupervisor.signal_bus_name()
    |> Jido.Signal.Bus.unsubscribe(subscription_id, opts)
  end

  defp dispatch_signal(nil, _signal), do: :ok

  defp dispatch_signal(instance_module, signal) do
    signal
    |> SignalDispatch.dispatch({:bus, target: MessagingSupervisor.signal_bus_name(instance_module)})
    |> normalize_dispatch_result()
  end

  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:error, reason}), do: {:error, reason}

  defp maybe_emit_telemetry(_signal, opts) do
    case Keyword.get(opts, :telemetry_event) do
      nil ->
        :ok

      event ->
        measurements = Keyword.get(opts, :telemetry_measurements, %{timestamp: DateTime.utc_now()})
        metadata = Keyword.get(opts, :telemetry_metadata, %{})
        :telemetry.execute(event, measurements, metadata)
    end
  end

  defp maybe_emit_legacy_pubsub(nil, _signal, _opts), do: :ok

  defp maybe_emit_legacy_pubsub(instance_module, signal, opts) do
    with legacy_event when not is_nil(legacy_event) <- Keyword.get(opts, :legacy_event),
         room_id when is_binary(room_id) <- Keyword.get(opts, :room_id) || signal.subject do
      case Jido.Messaging.PubSub.broadcast(instance_module, room_id, legacy_event) do
        :ok -> :ok
        {:error, :not_configured} -> :ok
      end
    else
      _other -> :ok
    end
  end
end
