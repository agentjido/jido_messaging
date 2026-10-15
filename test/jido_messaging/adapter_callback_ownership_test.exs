defmodule Jido.Messaging.AdapterCallbackOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.AdapterBridge

  defmodule ControlledAdapter do
    def listener_child_specs(bridge, opts), do: reply(:listener_child_specs, [bridge, opts])
    def ensure_ingress_subscription(bridge, opts), do: reply(:ensure_ingress_subscription, [bridge, opts])
    def list_ingress_subscriptions(bridge, opts), do: reply(:list_ingress_subscriptions, [bridge, opts])

    def delete_ingress_subscription(bridge, subscription, opts),
      do: reply(:delete_ingress_subscription, [bridge, subscription, opts])

    defp reply(callback, args) do
      send(self(), {:adapter_callback, callback, args})

      case Process.get(:adapter_callback_result) do
        :raise -> raise "private callback failure"
        :throw -> throw(:private_callback_failure)
        :exit -> exit(:private_callback_failure)
        result -> result
      end
    end
  end

  defmodule MissingAdapter do
  end

  for callback <- [
        :listener_child_specs,
        :ensure_ingress_subscription,
        :list_ingress_subscriptions,
        :delete_ingress_subscription
      ] do
    for {result, class, disposition} <- [
          {{:error, :timeout}, :recoverable, :retry},
          {{:error, {:policy_denied, :scope, :actor, :operation}}, :degraded, :degrade},
          {:invalid, :fatal, :crash},
          {:raise, :recoverable, :retry},
          {:throw, :fatal, :crash},
          {:exit, :fatal, :crash}
        ] do
      test "#{callback} retains one callback and #{inspect(result)} disposition" do
        callback = unquote(callback)
        Process.put(:adapter_callback_result, unquote(Macro.escape(result)))
        args = callback_args(callback)

        assert {:error, failure} = apply(AdapterBridge, callback, [ControlledAdapter | args])
        assert failure.type == :adapter_callback_failure
        assert failure.adapter == ControlledAdapter
        assert failure.callback == callback
        assert failure.class == unquote(class)
        assert failure.disposition == unquote(disposition)
        assert_receive {:adapter_callback, ^callback, ^args}
        refute_receive {:adapter_callback, _, _}, 0
      end
    end
  end

  test "listener absence and subscription absence do not call a provider" do
    assert {:ok, []} = AdapterBridge.listener_child_specs(MissingAdapter, "bridge")

    for callback <- [:ensure_ingress_subscription, :list_ingress_subscriptions, :delete_ingress_subscription] do
      assert {:error, :unsupported} = apply(AdapterBridge, callback, [MissingAdapter | callback_args(callback)])
    end

    refute_receive {:adapter_callback, _, _}, 0
  end

  for callback <- [:ensure_ingress_subscription, :list_ingress_subscriptions, :delete_ingress_subscription] do
    test "#{callback} keeps unsupported results and acknowledgement values" do
      callback = unquote(callback)
      args = callback_args(callback)

      for {input, expected} <- [
            {:ok, {:ok, %{}}},
            {{:ok, %{subscription_id: "owned"}}, {:ok, %{subscription_id: "owned"}}},
            {{:error, :unsupported}, {:error, :unsupported}},
            {{:error, {:unsupported, :provider_scope}}, {:error, {:unsupported, :provider_scope}}}
          ] do
        Process.put(:adapter_callback_result, input)
        assert apply(AdapterBridge, callback, [ControlledAdapter | args]) == expected
        assert_receive {:adapter_callback, ^callback, ^args}
      end

      refute_receive {:adapter_callback, _, _}, 0
    end
  end

  test "listener result keeps the selected bridge and original options" do
    args = callback_args(:listener_child_specs)
    spec = %{id: :owned_listener, start: {Task, :start_link, [fn -> :ok end]}}
    Process.put(:adapter_callback_result, {:ok, [spec]})
    assert {:ok, [^spec]} = apply(AdapterBridge, :listener_child_specs, [ControlledAdapter | args])
    assert_receive {:adapter_callback, :listener_child_specs, ^args}
    refute_receive {:adapter_callback, _, _}, 0
  end

  defp callback_args(:delete_ingress_subscription), do: ["caller-bridge", "owned-subscription", opts()]
  defp callback_args(_callback), do: ["caller-bridge", opts()]
  defp opts, do: [settings: %{private_value: "fixture"}, sink_mfa: {__MODULE__, :sink, []}]
end
