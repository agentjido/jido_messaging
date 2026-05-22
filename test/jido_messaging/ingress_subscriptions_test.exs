defmodule Jido.Messaging.IngressSubscriptionsTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{ConfigStore, IngressSubscription}

  defmodule ProvisioningAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}

    def ensure_ingress_subscription(bridge_id, opts) do
      notify(opts, {:ensure_subscription, bridge_id, opts})

      {:ok,
       %{
         "subscription_id" => "sub_#{bridge_id}",
         "external_id" => "provider_#{bridge_id}",
         "target_url" => Keyword.fetch!(opts, :target_url),
         "status" => "active",
         "metadata" => %{"scope" => Keyword.get(opts, :scope, "messages")},
         "raw" => %{"provider" => "fake"}
       }}
    end

    def list_ingress_subscriptions(bridge_id, opts) do
      notify(opts, {:list_subscriptions, bridge_id, opts})

      {:ok,
       [
         %{
           subscription_id: "provider_list_#{bridge_id}",
           external_id: "provider_list_external_#{bridge_id}",
           target_url: Keyword.get(opts, :target_url),
           status: :active,
           metadata: %{listed: true}
         }
       ]}
    end

    def delete_ingress_subscription(bridge_id, subscription_id, opts) do
      notify(opts, {:delete_subscription, bridge_id, subscription_id, opts})
      {:ok, %{subscription_id: subscription_id, status: :deleted}}
    end

    defp notify(opts, message) do
      settings = Keyword.get(opts, :settings, %{})

      case Map.get(settings, :test_pid) || Map.get(settings, "test_pid") do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule UnsupportedAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :slack

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule ErrorAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :github

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}

    def ensure_ingress_subscription(_bridge_id, _opts) do
      {:error, {:provider_error, 401, "bad credentials"}}
    end
  end

  defmodule SubscriptionMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(SubscriptionMessaging)
    :ok
  end

  test "ingress subscription normalization does not atomize arbitrary provider status values" do
    subscription =
      IngressSubscription.new(%{
        bridge_id: "bridge_status",
        adapter_name: :telegram,
        subscription_id: "provider-status",
        status: "provider-specific-status"
      })

    assert subscription.status == :unknown
  end

  test "ensure_ingress_subscription/2 calls adapter, normalizes result, and stores metadata" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_tg",
        adapter_module: ProvisioningAdapter,
        opts: %{ingress: %{target_url: "https://example.test/webhooks/tg"}, test_pid: self()}
      })

    assert {:ok, %IngressSubscription{} = subscription} =
             SubscriptionMessaging.ensure_ingress_subscription("bridge_tg", scope: "message.created")

    assert subscription.bridge_id == "bridge_tg"
    assert subscription.adapter_name == :telegram
    assert subscription.subscription_id == "sub_bridge_tg"
    assert subscription.external_id == "provider_bridge_tg"
    assert subscription.target_url == "https://example.test/webhooks/tg"
    assert subscription.status == :active
    assert subscription.metadata == %{"scope" => "message.created"}
    assert subscription.raw == %{"provider" => "fake"}

    assert_receive {:ensure_subscription, "bridge_tg", adapter_opts}
    assert Keyword.fetch!(adapter_opts, :bridge_id) == "bridge_tg"
    assert Keyword.fetch!(adapter_opts, :target_url) == "https://example.test/webhooks/tg"

    assert {:ok, [stored]} = ConfigStore.list_ingress_subscriptions(SubscriptionMessaging, "bridge_tg")
    assert stored.subscription_id == subscription.subscription_id
  end

  test "list_ingress_subscriptions/2 delegates to adapter and stores normalized provider records" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_provider_list",
        adapter_module: ProvisioningAdapter,
        opts: %{ingress: %{target_url: "https://example.test/provider-list"}, test_pid: self()}
      })

    assert {:ok, [%IngressSubscription{} = subscription]} =
             SubscriptionMessaging.list_ingress_subscriptions("bridge_provider_list")

    assert subscription.subscription_id == "provider_list_bridge_provider_list"
    assert subscription.external_id == "provider_list_external_bridge_provider_list"
    assert subscription.target_url == "https://example.test/provider-list"
    assert subscription.metadata == %{listed: true}

    assert_receive {:list_subscriptions, "bridge_provider_list", _adapter_opts}

    assert {:ok, [stored]} =
             ConfigStore.list_ingress_subscriptions(SubscriptionMessaging, "bridge_provider_list")

    assert stored.subscription_id == subscription.subscription_id
  end

  test "delete_ingress_subscription/3 delegates to adapter and clears stored metadata" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_delete",
        adapter_module: ProvisioningAdapter,
        opts: %{ingress: %{target_url: "https://example.test/delete"}, test_pid: self()}
      })

    assert {:ok, subscription} = SubscriptionMessaging.ensure_ingress_subscription("bridge_delete")

    assert {:ok, deleted} =
             SubscriptionMessaging.delete_ingress_subscription("bridge_delete", subscription.subscription_id)

    assert deleted.status == :deleted
    assert deleted.subscription_id == subscription.subscription_id

    assert_receive {:delete_subscription, "bridge_delete", "sub_bridge_delete", _adapter_opts}
    assert {:ok, []} = ConfigStore.list_ingress_subscriptions(SubscriptionMessaging, "bridge_delete")
  end

  test "list_ingress_subscriptions/2 falls back to stored metadata when adapter does not support listing" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_manual",
        adapter_module: UnsupportedAdapter
      })

    stored =
      IngressSubscription.new(%{
        bridge_id: "bridge_manual",
        adapter_name: :slack,
        subscription_id: "manual_setup",
        status: :manual_action_required,
        target_url: "https://example.test/manual"
      })

    assert {:ok, _stored} = ConfigStore.save_ingress_subscription(SubscriptionMessaging, stored)
    assert {:ok, [listed]} = SubscriptionMessaging.list_ingress_subscriptions("bridge_manual")
    assert listed.subscription_id == "manual_setup"
    assert listed.status == :manual_action_required
  end

  test "ensure_ingress_subscription/2 surfaces standardized unsupported adapter errors" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_unsupported",
        adapter_module: UnsupportedAdapter
      })

    assert {:error, error} = SubscriptionMessaging.ensure_ingress_subscription("bridge_unsupported")
    assert error.type == :ingress_subscription_error
    assert error.code == :unsupported
    assert error.bridge_id == "bridge_unsupported"
    assert error.adapter_name == :slack
    assert error.raw == :unsupported
  end

  test "ensure_ingress_subscription/2 preserves provider-specific adapter errors" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_error",
        adapter_module: ErrorAdapter
      })

    assert {:error, error} = SubscriptionMessaging.ensure_ingress_subscription("bridge_error")
    assert error.type == :ingress_subscription_error
    assert error.code == :adapter_error
    assert error.bridge_id == "bridge_error"
    assert error.adapter_name == :github
    assert error.reason == {:provider_error, 401, "bad credentials"}
    assert error.raw.reason == {:provider_error, 401, "bad credentials"}
  end

  test "ensure_ingress_subscription/2 rejects disabled bridges" do
    {:ok, _bridge} =
      SubscriptionMessaging.put_bridge_config(%{
        id: "bridge_disabled",
        adapter_module: ProvisioningAdapter,
        enabled: false
      })

    assert {:error, :bridge_disabled} =
             SubscriptionMessaging.ensure_ingress_subscription("bridge_disabled")
  end
end
