defmodule Jido.Messaging.AgentEndpointDelivery do
  @moduledoc """
  Bounded delivery envelope for a Jidoka-owned endpoint provider.

  Delivery is explicit. This module does not subscribe to messages, authorize
  invocation, retry work, or start an agent. The stable delivery ID lets the
  provider deduplicate a repeated authorized call.
  """

  alias Jido.Messaging.{AgentEndpointTarget, Message}

  @default_timeout 5_000
  @max_timeout 30_000

  @enforce_keys [:id, :endpoint, :membership, :route, :message, :attempted_at]
  defstruct [:id, :endpoint, :membership, :route, :message, :context, :attempted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          endpoint: Jido.Messaging.AgentMessagingEndpoint.t(),
          membership: Jido.Messaging.RoomMembership.t(),
          route: Jido.Messaging.AgentThreadRoute.t(),
          message: Message.t(),
          context: term(),
          attempted_at: DateTime.t()
        }

  @doc "Builds a stable endpoint delivery envelope for one canonical message."
  @spec new(AgentEndpointTarget.t(), Message.t(), term()) :: t()
  def new(%AgentEndpointTarget{} = target, %Message{} = message, context \\ nil) do
    %__MODULE__{
      id: delivery_id(target, message),
      endpoint: target.endpoint,
      membership: target.membership,
      route: target.route,
      message: message,
      context: context,
      attempted_at: DateTime.utc_now()
    }
  end

  @doc "Calls a Jidoka-owned provider within a bounded timeout."
  @spec deliver(module(), AgentEndpointTarget.t(), Message.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def deliver(provider, %AgentEndpointTarget{} = target, %Message{} = message, opts \\ [])
      when is_atom(provider) and is_list(opts) do
    context = Keyword.get(opts, :context)
    timeout = opts |> Keyword.get(:timeout, @default_timeout) |> normalize_timeout()
    provider_opts = Keyword.drop(opts, [:context, :timeout])
    delivery = new(target, message, context)

    with :ok <- validate_delivery(provider, target, message) do
      invoke_bounded(provider, delivery, provider_opts, timeout)
    end
  end

  defp validate_delivery(provider, target, message) do
    cond do
      not Code.ensure_loaded?(provider) or not function_exported?(provider, :deliver, 2) ->
        {:error, :endpoint_provider_unavailable}

      target.endpoint.status != :active ->
        {:error, {:endpoint_inactive, target.endpoint.status}}

      target.endpoint.availability != :available ->
        {:error, {:endpoint_unavailable, target.endpoint.availability}}

      target.membership.status != :active ->
        {:error, {:membership_inactive, target.membership.status}}

      target.route.status != :active ->
        {:error, {:route_inactive, target.route.status}}

      message.room_id != target.route.room_id ->
        {:error, :message_route_room_mismatch}

      message.thread_id != target.route.thread_id ->
        {:error, :message_route_thread_mismatch}

      true ->
        :ok
    end
  end

  defp invoke_bounded(provider, delivery, opts, timeout) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_provider_call(provider, delivery, opts)
        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_result(result, delivery.id)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:endpoint_provider_failed, failure_class(reason)}}
    after
      timeout ->
        Process.exit(pid, :kill)
        await_down(monitor_ref, pid)
        flush_result(result_ref)
        {:error, :endpoint_provider_timeout}
    end
  end

  defp safe_provider_call(provider, delivery, opts) do
    provider.deliver(delivery, opts)
  rescue
    exception -> {:error, {:provider_exception, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:provider_failure, kind}}
  end

  defp normalize_result(:ok, delivery_id), do: {:ok, %{delivery_id: delivery_id}}

  defp normalize_result({:ok, result}, delivery_id) when is_map(result),
    do: {:ok, Map.put_new(result, :delivery_id, delivery_id)}

  defp normalize_result({:error, _reason} = error, _delivery_id), do: error
  defp normalize_result(_result, _delivery_id), do: {:error, :invalid_endpoint_provider_response}

  defp normalize_timeout(value) when is_integer(value), do: value |> max(1) |> min(@max_timeout)
  defp normalize_timeout(_value), do: @default_timeout

  defp await_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      100 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp flush_result(result_ref) do
    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp failure_class(:normal), do: :normal_exit
  defp failure_class(:killed), do: :killed
  defp failure_class(_reason), do: :provider_exit

  defp delivery_id(target, message) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({target.endpoint.id, target.route.id, message.id})
      )

    "agent_delivery:" <> Base.url_encode64(digest, padding: false)
  end
end
