defmodule Jido.Messaging.OutboundRouterTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.OutboundRouter

  defmodule RouterMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule PrimaryFailAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:error, :send_failed}

    @impl true
    def edit_message(_external_room_id, _external_message_id, _text, _opts), do: {:error, :send_failed}
  end

  defmodule BackupOkAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(external_room_id, text, _opts), do: {:ok, %{message_id: "ok:#{external_room_id}:#{text}"}}

    @impl true
    def edit_message(_external_room_id, external_message_id, text, _opts),
      do: {:ok, %{message_id: "#{external_message_id}:#{text}"}}
  end

  defmodule DiscordOkAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :discord

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(external_room_id, text, _opts), do: {:ok, %{message_id: "ok:#{external_room_id}:#{text}"}}

    @impl true
    def edit_message(_external_room_id, external_message_id, text, _opts),
      do: {:ok, %{message_id: "#{external_message_id}:#{text}"}}
  end

  setup do
    start_supervised!(RouterMessaging)

    {:ok, room} = RouterMessaging.create_room(%{type: :direct, name: "Router Test"})

    {:ok, room: room}
  end

  test "resolve_routes/3 resolves enabled outbound bindings to adapter routes", %{room: room} do
    :ok = put_bridge("tg-primary", PrimaryFailAdapter)
    :ok = put_bridge("tg-backup", BackupOkAdapter)

    {:ok, _binding} =
      RouterMessaging.create_room_binding(room.id, :telegram, "tg-primary", "100", %{direction: :both})

    assert {:ok, routes} = OutboundRouter.resolve_routes(RouterMessaging, room.id)
    assert [%{bridge_id: "tg-primary", adapter_module: PrimaryFailAdapter, external_room_id: "100"}] = routes
  end

  test "route_outbound/4 fails over to next bridge when policy allows", %{room: room} do
    :ok = put_bridge("tg-primary", PrimaryFailAdapter)
    :ok = put_bridge("tg-backup", BackupOkAdapter)

    {:ok, _binding_primary} =
      RouterMessaging.create_room_binding(room.id, :telegram, "tg-primary", "100", %{direction: :both})

    {:ok, _binding_backup} =
      RouterMessaging.create_room_binding(room.id, :telegram, "tg-backup", "200", %{direction: :both})

    {:ok, _policy} =
      RouterMessaging.put_routing_policy(room.id, %{
        fallback_order: ["tg-primary", "tg-backup"],
        failover_policy: :next_available
      })

    assert {:ok, summary} = OutboundRouter.route_outbound(RouterMessaging, room.id, "hello")

    assert summary.attempted == 2
    assert length(summary.delivered) == 1
    assert length(summary.failed) == 1
    assert hd(summary.delivered).route.bridge_id == "tg-backup"
    assert hd(summary.failed).route.bridge_id == "tg-primary"
    assert hd(summary.delivered).result.message_id == "ok:200:hello"
  end

  test "route_outbound/4 prefers binding bridge_id over legacy instance_id", %{room: room} do
    :ok = put_bridge("tg-primary", PrimaryFailAdapter)
    :ok = put_bridge("tg-backup", BackupOkAdapter)

    {:ok, _binding} =
      RouterMessaging.create_room_binding(room.id, :telegram, "legacy_instance", "300", %{
        direction: :both,
        bridge_id: "tg-backup"
      })

    assert {:ok, summary} = OutboundRouter.route_outbound(RouterMessaging, room.id, "bridge-id")
    assert length(summary.delivered) == 1
    assert summary.failed == []
    assert hd(summary.delivered).route.bridge_id == "tg-backup"
    assert hd(summary.delivered).result.message_id == "ok:300:bridge-id"
  end

  test "route_outbound/4 broadcasts to all configured routes", %{room: room} do
    :ok = put_bridge("tg-backup", BackupOkAdapter)
    :ok = put_bridge("dc-primary", DiscordOkAdapter)

    {:ok, _binding_telegram} =
      RouterMessaging.create_room_binding(room.id, :telegram, "tg-backup", "100", %{direction: :both})

    {:ok, _binding_discord} =
      RouterMessaging.create_room_binding(room.id, :discord, "dc-primary", "555", %{direction: :outbound})

    {:ok, _policy} = RouterMessaging.put_routing_policy(room.id, %{delivery_mode: :broadcast})

    assert {:ok, summary} = OutboundRouter.route_outbound(RouterMessaging, room.id, "fanout")
    assert summary.attempted == 2
    assert length(summary.delivered) == 2
    assert summary.failed == []
  end

  test "route_outbound/4 returns :no_routes when no bindings exist", %{room: room} do
    :ok = put_bridge("tg-backup", BackupOkAdapter)
    assert {:error, :no_routes} = OutboundRouter.route_outbound(RouterMessaging, room.id, "nothing")
  end

  defp put_bridge(id, adapter_module) do
    case RouterMessaging.put_bridge_config(%{id: id, adapter_module: adapter_module}) do
      {:ok, _config} -> :ok
      {:error, reason} -> flunk("failed to put bridge config #{id}: #{inspect(reason)}")
    end
  end
end
