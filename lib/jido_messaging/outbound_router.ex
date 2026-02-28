defmodule Jido.Messaging.OutboundRouter do
  @moduledoc """
  Outbound bridge router for runtime-configurable adapter delivery.

  Resolves `RoomBinding` + `BridgeConfig` + `RoutingPolicy`, then dispatches
  through `Jido.Messaging.OutboundGateway`.
  """

  alias Jido.Messaging.{BridgeConfig, ConfigStore, OutboundGateway, RoutingPolicy, RoomBinding}

  @type route :: %{
          required(:binding_id) => String.t(),
          required(:bridge_id) => String.t(),
          required(:adapter_module) => module(),
          required(:channel) => atom(),
          required(:external_room_id) => String.t()
        }

  @type delivery_success :: %{
          required(:route) => route(),
          required(:result) => OutboundGateway.success_response()
        }

  @type delivery_failure :: %{
          required(:route) => route(),
          required(:reason) => term(),
          required(:error) => OutboundGateway.error_response() | term()
        }

  @type delivery_summary :: %{
          required(:room_id) => String.t(),
          required(:policy) => RoutingPolicy.t(),
          required(:attempted) => non_neg_integer(),
          required(:delivered) => [delivery_success()],
          required(:failed) => [delivery_failure()]
        }

  @doc """
  Resolves outbound routes for a room from bindings + bridge configs.

  The returned list is ordered according to routing policy fallback order.
  """
  @spec resolve_routes(module(), String.t(), keyword()) :: {:ok, [route()]} | {:error, term()}
  def resolve_routes(instance_module, room_id, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_list(opts) do
    with {:ok, _policy, routes} <- resolve(instance_module, room_id, opts) do
      {:ok, routes}
    end
  end

  @doc """
  Routes an outbound text payload for a room.

  ## Options

    * `:gateway_opts` - options passed to `OutboundGateway.send_message/4`
    * `:bridge_id` - force a specific bridge id
    * `:routing_policy` - override stored routing policy (`RoutingPolicy` or map)
  """
  @spec route_outbound(module(), String.t(), String.t(), keyword()) ::
          {:ok, delivery_summary()} | {:error, :no_routes | {:delivery_failed, delivery_summary()} | term()}
  def route_outbound(instance_module, room_id, text, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_binary(text) and is_list(opts) do
    gateway_opts = Keyword.get(opts, :gateway_opts, [])

    with {:ok, policy, routes} <- resolve(instance_module, room_id, opts),
         false <- Enum.empty?(routes) do
      {delivered, failed} = dispatch_routes(instance_module, room_id, text, routes, policy, gateway_opts)

      summary = %{
        room_id: room_id,
        policy: policy,
        attempted: length(delivered) + length(failed),
        delivered: delivered,
        failed: failed
      }

      if delivered == [] do
        {:error, {:delivery_failed, summary}}
      else
        {:ok, summary}
      end
    else
      true -> {:error, :no_routes}
      {:error, _reason} = error -> error
    end
  end

  defp resolve(instance_module, room_id, opts) do
    with {:ok, bindings} <- list_room_bindings(instance_module, room_id),
         bridges <- ConfigStore.list_bridge_configs(instance_module, enabled: true),
         policy <- resolve_policy(instance_module, room_id, opts) do
      routes =
        bindings
        |> Enum.filter(&eligible_outbound_binding?/1)
        |> build_routes(bridges, policy, opts)
        |> order_routes(policy)

      {:ok, policy, routes}
    end
  end

  defp list_room_bindings(instance_module, room_id) do
    runtime = Module.concat(instance_module, :Runtime)
    Jido.Messaging.list_room_bindings(runtime, room_id)
  end

  defp resolve_policy(instance_module, room_id, opts) do
    case Keyword.get(opts, :routing_policy) do
      %RoutingPolicy{} = policy ->
        policy

      policy when is_map(policy) ->
        RoutingPolicy.new(Map.put(policy, :room_id, room_id))

      _ ->
        case ConfigStore.get_routing_policy(instance_module, room_id) do
          {:ok, %RoutingPolicy{} = policy} -> policy
          {:error, :not_found} -> RoutingPolicy.new(%{room_id: room_id})
        end
    end
  end

  defp eligible_outbound_binding?(%RoomBinding{enabled: enabled, direction: direction}) do
    enabled and direction in [:outbound, :both]
  end

  defp build_routes(bindings, bridges, policy, opts) do
    bridge_by_id = Map.new(bridges, &{&1.id, &1})
    bridges_by_channel = Enum.group_by(bridges, &adapter_type(&1.adapter_module))
    forced_bridge_id = Keyword.get(opts, :bridge_id)

    bindings
    |> Enum.reduce([], fn binding, acc ->
      case resolve_bridge(binding, bridge_by_id, bridges_by_channel, policy, forced_bridge_id) do
        nil -> acc
        %BridgeConfig{} = bridge -> [build_route(binding, bridge) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp resolve_bridge(binding, bridge_by_id, bridges_by_channel, policy, forced_bridge_id) do
    ids =
      [forced_bridge_id, binding_bridge_id(binding) | policy.fallback_order]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    case Enum.find(ids, fn id -> matching_bridge?(Map.get(bridge_by_id, id), binding.channel) end) do
      nil ->
        bridges_by_channel
        |> Map.get(binding.channel, [])
        |> Enum.sort_by(& &1.id)
        |> List.first()

      id ->
        Map.get(bridge_by_id, id)
    end
  end

  defp matching_bridge?(nil, _channel), do: false
  defp matching_bridge?(%BridgeConfig{} = bridge, channel), do: adapter_type(bridge.adapter_module) == channel

  defp build_route(%RoomBinding{} = binding, %BridgeConfig{} = bridge) do
    %{
      binding_id: binding.id,
      bridge_id: bridge.id,
      adapter_module: bridge.adapter_module,
      channel: binding.channel,
      external_room_id: binding.external_room_id
    }
  end

  defp order_routes(routes, %RoutingPolicy{fallback_order: []}), do: routes

  defp order_routes(routes, %RoutingPolicy{fallback_order: fallback_order}) do
    order =
      fallback_order
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(routes, fn route -> {Map.get(order, route.bridge_id, 1_000_000), route.bridge_id} end)
  end

  defp dispatch_routes(instance_module, room_id, text, routes, policy, gateway_opts) do
    case policy.delivery_mode do
      :broadcast ->
        dispatch_all(instance_module, room_id, text, routes, gateway_opts)

      _ ->
        dispatch_with_failover(
          instance_module,
          room_id,
          text,
          routes,
          policy.failover_policy,
          gateway_opts
        )
    end
  end

  defp dispatch_with_failover(_instance_module, _room_id, _text, [], _policy, _gateway_opts), do: {[], []}

  defp dispatch_with_failover(instance_module, room_id, text, routes, :broadcast, gateway_opts) do
    dispatch_all(instance_module, room_id, text, routes, gateway_opts)
  end

  defp dispatch_with_failover(instance_module, room_id, text, [route | rest], failover_policy, gateway_opts) do
    case dispatch_once(instance_module, room_id, text, route, gateway_opts) do
      {:ok, delivered} ->
        {[delivered], []}

      {:error, failed} ->
        case {failover_policy, rest} do
          {:next_available, [_ | _]} ->
            {delivered, failed_rest} =
              dispatch_with_failover(instance_module, room_id, text, rest, :next_available, gateway_opts)

            {delivered, [failed | failed_rest]}

          _ ->
            {[], [failed]}
        end
    end
  end

  defp dispatch_all(instance_module, room_id, text, routes, gateway_opts) do
    Enum.reduce(routes, {[], []}, fn route, {delivered, failed} ->
      case dispatch_once(instance_module, room_id, text, route, gateway_opts) do
        {:ok, success} -> {[success | delivered], failed}
        {:error, error} -> {delivered, [error | failed]}
      end
    end)
    |> then(fn {delivered, failed} -> {Enum.reverse(delivered), Enum.reverse(failed)} end)
  end

  defp dispatch_once(instance_module, room_id, text, route, gateway_opts) do
    context = %{
      room_id: room_id,
      channel: route.adapter_module,
      bridge_id: route.bridge_id,
      external_room_id: route.external_room_id
    }

    case OutboundGateway.send_message(instance_module, context, text, gateway_opts) do
      {:ok, result} ->
        {:ok, %{route: route, result: result}}

      {:error, error} ->
        {:error,
         %{
           route: route,
           reason: unwrap_gateway_error(error),
           error: error
         }}
    end
  end

  defp unwrap_gateway_error(%{reason: reason}), do: reason

  defp adapter_type(adapter_module) do
    if function_exported?(adapter_module, :channel_type, 0) do
      adapter_module.channel_type()
    else
      adapter_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()
    end
  end

  defp binding_bridge_id(%RoomBinding{} = binding) do
    binding.bridge_id
  end
end
