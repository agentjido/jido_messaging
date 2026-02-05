defmodule JidoMessaging.Adapters.Heartbeat do
  @moduledoc """
  Behaviour for channel-specific health checking.

  Provides a standardized callback for channels to implement custom health checks
  that probe the underlying platform connection.

  ## Implementation

  Channels can implement this behaviour to provide platform-specific health checks:

      defmodule MyApp.Channels.Telegram do
        @behaviour JidoMessaging.Channel
        @behaviour JidoMessaging.Adapters.Heartbeat

        @impl JidoMessaging.Adapters.Heartbeat
        def check_health(instance) do
          case Telegex.get_me() do
            {:ok, _bot_info} -> :ok
            {:error, reason} -> {:error, {:api_error, reason}}
          end
        end

        @impl JidoMessaging.Adapters.Heartbeat
        def probe_interval_ms, do: :timer.seconds(30)
      end

  ## Default Implementations

  All callbacks are optional:

    * `check_health/1` - Returns `:ok` if not implemented
    * `probe_interval_ms/0` - Returns `30_000` (30 seconds) if not implemented

  ## Integration

  The InstanceServer can use this behaviour to perform periodic health probes:

      if function_exported?(channel_module, :check_health, 1) do
        case channel_module.check_health(instance) do
          :ok -> InstanceServer.notify_connected(pid)
          {:error, reason} -> InstanceServer.notify_disconnected(pid, reason)
        end
      end
  """

  alias JidoMessaging.Instance

  @doc """
  Performs a health check on the channel instance.

  Should probe the underlying platform connection and return:
    * `:ok` - Connection is healthy
    * `{:error, reason}` - Connection is unhealthy

  ## Parameters

    * `instance` - The Instance struct containing credentials and settings

  ## Examples

      def check_health(%Instance{} = instance) do
        case MyAPI.ping(instance.credentials.api_key) do
          {:ok, _} -> :ok
          {:error, :timeout} -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
        end
      end
  """
  @callback check_health(instance :: Instance.t()) :: :ok | {:error, term()}

  @doc """
  Returns the recommended interval between health probes in milliseconds.

  This is advisory - the actual probe schedule is controlled by the caller.
  """
  @callback probe_interval_ms() :: pos_integer()

  @optional_callbacks check_health: 1, probe_interval_ms: 0

  @default_probe_interval_ms :timer.seconds(30)

  @doc """
  Safely performs a health check for a module.

  Returns `:ok` if the module doesn't implement the callback.
  """
  @spec check_health(module(), Instance.t()) :: :ok | {:error, term()}
  def check_health(module, %Instance{} = instance) do
    if function_exported?(module, :check_health, 1) do
      module.check_health(instance)
    else
      :ok
    end
  end

  @doc """
  Gets the probe interval for a module.

  Returns the default (30 seconds) if the module doesn't implement the callback.
  """
  @spec probe_interval_ms(module()) :: pos_integer()
  def probe_interval_ms(module) do
    if function_exported?(module, :probe_interval_ms, 0) do
      module.probe_interval_ms()
    else
      @default_probe_interval_ms
    end
  end

  @doc """
  Checks if a module implements the Heartbeat behaviour.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) do
    function_exported?(module, :check_health, 1)
  end
end
