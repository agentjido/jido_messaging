defmodule Jido.Messaging.OutboundRouterTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.OutboundRouter

  defmodule RouterMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule PrimaryFailAdapter do
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _payload), do: Jido.Chat.Delivery.new(binding, "empty", [])

    @impl true
    def send_message(_external_room_id, _text, _opts) do
      send(Process.whereis(Jido.Messaging.OutboundRouterTest.Probe), {:provider_call, __MODULE__})
      {:error, :send_failed}
    end

    @impl true
    def edit_message(_external_room_id, _external_message_id, _text, _opts), do: {:error, :send_failed}
  end

  defmodule BackupOkAdapter do
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _payload), do: Jido.Chat.Delivery.new(binding, "empty", [])

    @impl true
    def send_message(external_room_id, text, _opts) do
      send(Process.whereis(Jido.Messaging.OutboundRouterTest.Probe), {:provider_call, __MODULE__})
      {:ok, %{message_id: "ok:#{external_room_id}:#{text}"}}
    end

    @impl true
    def edit_message(_external_room_id, external_message_id, text, _opts),
      do: {:ok, %{message_id: "#{external_message_id}:#{text}"}}
  end

  defmodule DiscordOkAdapter do
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :discord

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _payload), do: Jido.Chat.Delivery.new(binding, "empty", [])

    @impl true
    def send_message(external_room_id, text, _opts) do
      send(Process.whereis(Jido.Messaging.OutboundRouterTest.Probe), {:provider_call, __MODULE__})
      {:ok, %{message_id: "ok:#{external_room_id}:#{text}"}}
    end

    @impl true
    def edit_message(_external_room_id, external_message_id, text, _opts),
      do: {:ok, %{message_id: "#{external_message_id}:#{text}"}}
  end

  setup do
    Process.register(self(), Jido.Messaging.OutboundRouterTest.Probe)
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
    assert hd(summary.failed).error.category == :terminal
    assert hd(summary.delivered).result.message_id == "ok:200:hello"
    assert_received {:provider_call, PrimaryFailAdapter}
    assert_received {:provider_call, BackupOkAdapter}
    refute_received {:provider_call, _}
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
    assert_received {:provider_call, BackupOkAdapter}
    assert_received {:provider_call, DiscordOkAdapter}
    refute_received {:provider_call, _}
  end

  test "route_outbound/4 returns :no_routes when no bindings exist", %{room: room} do
    :ok = put_bridge("tg-backup", BackupOkAdapter)
    assert {:error, :no_routes} = OutboundRouter.route_outbound(RouterMessaging, room.id, "nothing")
  end

  defp actor(room, bridge \\ nil) do
    {:ok, participant} = RouterMessaging.create_participant(%{type: :human})

    {:ok, _} =
      RouterMessaging.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    scope = Jido.Messaging.AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: bridge})

    {:ok, grant} =
      RouterMessaging.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope
      })

    {[principal_id: participant.id, authorization_scope: scope], grant}
  end

  defp route_request(room, id),
    do: Jido.Messaging.Signal.SendMessage.new!(%{"request_id" => id, "room_id" => room.id, "text" => "hello"})

  test "typed routing keeps failover counts and a closed result", %{room: room} do
    :ok = put_bridge("primary", PrimaryFailAdapter)
    :ok = put_bridge("backup", BackupOkAdapter)
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :telegram, "primary", "100", %{direction: :both})
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :telegram, "backup", "200", %{direction: :both})

    {:ok, _} =
      RouterMessaging.put_routing_policy(room.id, %{
        fallback_order: ["primary", "backup"],
        failover_policy: :next_available
      })

    {actor, _grant} = actor(room)
    request = route_request(room, "failover")
    assert {:ok, result} = RouterMessaging.execute(request, actor)
    assert result.type == "jido.messaging.operation.completed"
    assert result.data["operation"] == "route_outbound"
    assert result.data["result"]["attempted"] == 2
    assert [%{"bridge_id" => "backup"}] = result.data["result"]["delivered"]
    assert [%{"bridge_id" => "primary"}] = result.data["result"]["failed"]
    assert_received {:provider_call, PrimaryFailAdapter}
    assert_received {:provider_call, BackupOkAdapter}
    assert {:ok, ^result} = RouterMessaging.execute(request, actor)
    refute_received {:provider_call, _}
    assert {:ok, encoded} = Jido.Signal.Serialization.serialize(result)
    {:ok, catalog} = Jido.Messaging.Runtime.catalog(RouterMessaging.__jido_messaging__(:runtime))
    assert {:ok, ^result} = Jido.Signal.Catalog.decode(catalog, encoded)
    assert Jido.Signal.Context.get(result, "causationid") == request.id
  end

  test "typed broadcast authorizes all routes before two callbacks", %{room: room} do
    :ok = put_bridge("telegram", BackupOkAdapter)
    :ok = put_bridge("discord", DiscordOkAdapter)
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :telegram, "telegram", "100", %{direction: :both})
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :discord, "discord", "200", %{direction: :both})
    {:ok, _} = RouterMessaging.put_routing_policy(room.id, %{delivery_mode: :broadcast})
    {actor, grant} = actor(room)
    request = route_request(room, "broadcast")
    assert {:ok, result} = RouterMessaging.execute(request, actor)
    assert length(result.data["result"]["delivered"]) == 2
    assert_received {:provider_call, BackupOkAdapter}
    assert_received {:provider_call, DiscordOkAdapter}
    assert {:ok, _} = RouterMessaging.revoke_principal_grant(grant.id, grant.revision)
    assert {:ok, denied} = RouterMessaging.execute(request, actor)
    assert denied.data["code"] == "authorization_denied"
    refute_received {:provider_call, _}
  end

  test "a route without a grant causes zero callbacks before any route starts", %{room: room} do
    :ok = put_bridge("telegram", BackupOkAdapter)
    :ok = put_bridge("discord", DiscordOkAdapter)
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :telegram, "telegram", "100", %{direction: :both})
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :discord, "discord", "200", %{direction: :both})
    {:ok, _} = RouterMessaging.put_routing_policy(room.id, %{delivery_mode: :broadcast})
    {actor, _} = actor(room, "telegram")
    scope = %{actor[:authorization_scope] | bridge_id: nil}

    assert {:ok, denied} =
             RouterMessaging.execute(route_request(room, "denied"), Keyword.put(actor, :authorization_scope, scope))

    assert denied.data["code"] == "authorization_denied"
    refute_received {:provider_call, _}
  end

  test "typed routing retains every failure and never repeats accepted callbacks", %{room: room} do
    :ok = put_bridge("primary", PrimaryFailAdapter)
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :telegram, "primary", "100", %{direction: :both})
    {actor, _} = actor(room)
    request = route_request(room, "all-failed")
    assert {:ok, result} = RouterMessaging.execute(request, actor)
    assert result.type == "jido.messaging.operation.failed"
    assert result.data["result"]["attempted"] == 1
    assert [%{"bridge_id" => "primary", "code" => "provider_failure"}] = result.data["result"]["failed"]
    assert_received {:provider_call, PrimaryFailAdapter}
    assert {:ok, ^result} = RouterMessaging.execute(request, actor)
    refute_received {:provider_call, _}
    assert {:ok, encoded} = Jido.Signal.Serialization.serialize(result)
    {:ok, catalog} = Jido.Messaging.Runtime.catalog(RouterMessaging.__jido_messaging__(:runtime))
    assert {:ok, ^result} = Jido.Signal.Catalog.decode(catalog, encoded)
    refute function_exported?(RouterMessaging, :route_outbound, 2)
  end

  test "failed publication cannot repeat a typed broadcast", %{room: room} do
    :ok = put_bridge("telegram", BackupOkAdapter)
    :ok = put_bridge("discord", DiscordOkAdapter)
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :telegram, "telegram", "100", %{direction: :both})
    {:ok, _} = RouterMessaging.create_room_binding(room.id, :discord, "discord", "200", %{direction: :both})
    {:ok, _} = RouterMessaging.put_routing_policy(room.id, %{delivery_mode: :broadcast})
    {actor, _} = actor(room)
    supervisor = RouterMessaging.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(RouterMessaging.signal_bus_name())
    {id, ^bus, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == bus end)
    :ok = Supervisor.terminate_child(supervisor, id)
    request = route_request(room, "observation-failed")
    assert {:ok, failed} = RouterMessaging.execute(request, actor)
    assert failed.data["code"] == "observation_failed"
    assert_received {:provider_call, BackupOkAdapter}
    assert_received {:provider_call, DiscordOkAdapter}
    assert {:ok, ^failed} = RouterMessaging.execute(request, actor)
    refute_received {:provider_call, _}
  end

  test "no selected routes return a typed unsupported result", %{room: room} do
    {actor, _} = actor(room)
    assert {:ok, failed} = RouterMessaging.execute(route_request(room, "none"), actor)
    assert failed.type == "jido.messaging.operation.failed"
    assert failed.data["code"] == "unsupported"
    assert failed.data["result"]["attempted"] == 0
    refute_received {:provider_call, _}
  end

  defp put_bridge(id, adapter_module) do
    case RouterMessaging.put_bridge_config(%{id: id, adapter_module: adapter_module}) do
      {:ok, _config} -> :ok
      {:error, reason} -> flunk("failed to put bridge config #{id}: #{inspect(reason)}")
    end
  end
end
