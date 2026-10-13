defmodule Jido.Messaging.IngressSubscriptionRecordTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{ConfigStore, IngressSubscription}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  test "string records retain identifiers, parsed expiry and exact private metadata in each bridge" do
    start_supervised!(Instance)
    expiry = ~U[2026-10-14 04:00:00Z]
    private = %{"provider" => %{"private-context" => "complete"}}

    for bridge <- ["owned", "other"] do
      record =
        IngressSubscription.new(%{
          "bridge_id" => bridge,
          "adapter" => "telegram",
          "id" => 123,
          "external_id" => 456,
          "webhook_url" => "https://fixture.invalid/owned",
          "expires_at" => "2026-10-14T04:00:00Z",
          "status" => "DISABLED",
          "metadata" => private,
          "raw" => %{"fixture" => ["all", "items"]}
        })

      assert record.bridge_id == bridge
      assert record.adapter_name == :telegram
      assert record.subscription_id == "123"
      assert record.external_id == "456"
      assert record.status == :disabled
      assert record.expires_at == expiry
      assert record.target_url == "https://fixture.invalid/owned"
      assert record.metadata == private
      assert record.raw == %{"fixture" => ["all", "items"]}
      assert {:ok, ^record} = ConfigStore.save_ingress_subscription(Instance, record)
      assert {:ok, [^record]} = ConfigStore.list_ingress_subscriptions(Instance, bridge)
    end

    assert :ok = ConfigStore.delete_ingress_subscription(Instance, "owned", "123")
    assert {:ok, []} = ConfigStore.list_ingress_subscriptions(Instance, "owned")
    assert {:ok, [other]} = ConfigStore.list_ingress_subscriptions(Instance, "other")
    assert other.metadata == private
    assert {:ok, []} = Instance.list_rooms()
  end

  test "fixed statuses normalize safely and unknown provider values create no atoms" do
    for status <- [:active, :deleted, :disabled, :expired, :manual_action_required, :pending] do
      record = IngressSubscription.new(%{bridge_id: "bridge", adapter_name: :telegram, status: Atom.to_string(status)})
      assert record.status == status
    end

    unknown = "provider_status_#{System.unique_integer([:positive])}"

    record =
      IngressSubscription.new(%{
        bridge_id: "bridge",
        adapter_name: unknown,
        status: unknown,
        expires_at: "invalid-time",
        metadata: :invalid
      })

    assert record.adapter_name == :unknown
    assert record.status == :unknown
    assert record.subscription_id == "bridge"
    assert record.external_id == "bridge"
    assert record.expires_at == nil
    assert record.metadata == %{}
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "module adapter, direct expiry and identity fallback retain deterministic values" do
    expiry = ~U[2026-10-14 04:00:00Z]

    for {attrs, expected} <- [
          {%{external_id: "external"}, "external"},
          {%{target_url: "https://fixture.invalid/target"}, "https://fixture.invalid/target"},
          {%{}, "bridge"}
        ] do
      record =
        IngressSubscription.new(
          Map.merge(
            %{bridge_id: "bridge", adapter_name: Jido.Chat.Telegram.Adapter, expires_at: expiry, status: 1},
            attrs
          )
        )

      assert record.adapter_name == :adapter
      assert record.subscription_id == expected
      assert record.expires_at == expiry
      assert record.status == :unknown
    end
  end
end
