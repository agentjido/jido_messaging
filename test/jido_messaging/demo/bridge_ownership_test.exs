defmodule Jido.Messaging.Demo.BridgeOwnershipTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{AuthorizationScope, Events, Runtime}
  alias Jido.Messaging.Demo.Bridge

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule Telegram do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :telegram
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    @impl true
    def send_message(room, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_send, :telegram, room, text})
      {:ok, %{id: "telegram-sent"}}
    end
  end

  defmodule Discord do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :discord
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    @impl true
    def send_message(room, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_send, :discord, room, text})
      {:ok, %{id: "discord-sent"}}
    end
  end

  setup do
    start_supervised!(Instance)
    {:ok, actor} = Instance.create_participant(%{id: "bridge-actor", type: :human})

    for {adapter, id} <- [{Telegram, "tg"}, {Discord, "dc"}] do
      {:ok, binding} = Jido.Chat.bind(adapter, id: id, test_pid: self())
      assert :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    end

    {:ok, bridge} =
      start_supervised(
        {Bridge,
         instance_module: Instance,
         principal_id: actor.id,
         telegram_adapter: Telegram,
         discord_adapter: Discord,
         telegram_bridge_id: "tg",
         discord_bridge_id: "dc",
         telegram_chat_id: "tg-room",
         discord_channel_id: "dc-room"}
      )

    await_subscribed(bridge)

    grants =
      for id <- ["tg", "dc"] do
        {:ok, grant} =
          Instance.create_principal_grant(%{
            principal_id: actor.id,
            issuer_principal_id: "host",
            actions: [:post_message],
            scope: AuthorizationScope.new(%{kind: :room, room_id: "demo:lobby", bridge_id: id}),
            constraints: %{requires_membership: false}
          })

        {id, grant}
      end
      |> Map.new()

    {:ok, bridge: bridge, actor: actor, grants: grants}
  end

  test "stored facts forward once to the other captured binding", %{bridge: bridge} do
    {message, fact} = stored_fact("first", :telegram)
    {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
    assert {:ok, ^fact} = Jido.Signal.Catalog.validate(catalog, fact)
    assert fact.data["message_id"] == message.id

    request =
      Jido.Messaging.Signal.SendMessage.new!(%{
        "request_id" => "direct-control",
        "room_id" => "demo:lobby",
        "bridge_id" => "dc",
        "text" => "direct-control"
      })

    assert {:ok, direct} =
             Instance.execute(request,
               principal_id: "bridge-actor",
               authorization_scope: AuthorizationScope.new(%{kind: :room, room_id: "demo:lobby", bridge_id: "dc"})
             )

    assert direct.data["code"] == nil
    assert direct.type == "jido.messaging.operation.completed"
    assert_receive {:provider_send, :discord, "dc-room", "direct-control"}
    send(bridge, {:signal, fact})
    :sys.get_state(bridge)
    assert_receive {:provider_send, :discord, "dc-room", "[TG alice] hello"}
    refute_receive {:provider_send, :telegram, _, _}, 0
    send(bridge, {:signal, fact})
    :sys.get_state(bridge)
    refute_receive {:provider_send, _, _, _}, 0
    assert {:ok, ^message} = Instance.get_message(message.id)
  end

  test "malformed or foreign facts cause no callback", %{bridge: bridge} do
    {_message, fact} = stored_fact("selected", :telegram)
    {:ok, foreign_room} = Instance.create_room(%{id: "foreign-room", type: :group})

    {:ok, foreign_message} =
      Instance.save_message(%{
        id: "foreign-message",
        room_id: foreign_room.id,
        sender_id: "sender",
        role: :user,
        content: [%{type: :text, text: "foreign"}]
      })

    for invalid <- [
          Map.from_struct(fact),
          %{fact | source: "urn:foreign:instance"},
          %{fact | subject: "room:foreign"},
          %{fact | dataschema: "urn:unknown:schema"},
          %{fact | data: Map.put(fact.data, "message_id", foreign_message.id)}
        ] do
      send(bridge, {:signal, invalid})
      :sys.get_state(bridge)
      refute_receive {:provider_send, _, _, _}, 0
    end
  end

  test "revocation precedes repeated request cache access", %{bridge: bridge, grants: grants} do
    {_message, fact} = stored_fact("revoked", :telegram)
    send(bridge, {:signal, fact})
    :sys.get_state(bridge)
    assert_receive {:provider_send, :discord, "dc-room", _}
    assert {:ok, _} = Instance.revoke_principal_grant(grants["dc"].id, grants["dc"].revision)
    send(bridge, {:signal, fact})
    :sys.get_state(bridge)
    refute_receive {:provider_send, _, _, _}, 0
    {_message, new_fact} = stored_fact("after-revoke", :telegram)
    send(bridge, {:signal, new_fact})
    :sys.get_state(bridge)
    refute_receive {:provider_send, _, _, _}, 0
  end

  for {kind, attrs} <- [
        {:disabled, %{enabled: false, direction: :both}},
        {:inbound, %{enabled: true, direction: :inbound}}
      ] do
    test "#{kind} indexed room binding has no provider effect", %{bridge: bridge} do
      {:ok, routes} = Instance.list_room_bindings("demo:lobby")
      route = Enum.find(routes, &(&1.bridge_id == "dc"))
      assert :ok = Instance.delete_room_binding(route.id)

      assert {:ok, _} =
               Instance.create_room_binding("demo:lobby", :discord, "dc", "dc-room", unquote(Macro.escape(attrs)))

      {_message, fact} = stored_fact(unquote(Atom.to_string(kind)), :telegram)
      send(bridge, {:signal, fact})
      :sys.get_state(bridge)
      refute_receive {:provider_send, _, _, _}, 0
    end
  end

  test "ambiguous indexed room bindings cause no provider effect", %{bridge: bridge} do
    assert {:ok, _} =
             Instance.create_room_binding("demo:lobby", :discord, "dc", "second-dc-room", %{
               enabled: true,
               direction: :both
             })

    {_message, fact} = stored_fact("ambiguous", :telegram)
    send(bridge, {:signal, fact})
    :sys.get_state(bridge)
    refute_receive {:provider_send, _, _, _}, 0
  end

  test "missing actor has no inferred grant or provider call", %{bridge: bridge, actor: actor} do
    {:ok, grants_before} = Instance.list_principal_grants(actor.id)
    :sys.replace_state(bridge, &%{&1 | principal_id: nil})
    {_message, fact} = stored_fact("missing-actor", :telegram)
    send(bridge, {:signal, fact})
    :sys.get_state(bridge)
    refute_receive {:provider_send, _, _, _}, 0
    assert {:ok, ^grants_before} = Instance.list_principal_grants(actor.id)
  end

  test "native Bus delivery keeps instance and room selection", %{bridge: bridge} do
    {_message, fact} = stored_fact("bus-message", :discord)
    bus = Module.concat(Instance, SignalBus)
    assert {:ok, _} = Jido.Signal.Bus.publish(bus, [%{fact | source: "urn:foreign:instance"}])
    assert {:ok, _} = Jido.Signal.Bus.publish(bus, [%{fact | subject: "room:foreign"}])
    :sys.get_state(bridge)
    refute_receive {:provider_send, _, _, _}, 0
    assert {:ok, _} = Jido.Signal.Bus.publish(bus, [fact])
    assert_receive {:provider_send, :telegram, "tg-room", "[DC alice] hello"}, 1_000
    refute_receive {:provider_send, :discord, _, _}, 0
  end

  test "supervisor preserves the explicit forwarding actor" do
    assert {:ok, {_flags, children}} =
             Jido.Messaging.Demo.Supervisor.init(
               mode: :bridge,
               principal_id: "explicit-actor",
               telegram_adapter: Telegram,
               discord_adapter: Discord,
               telegram_chat_id: "tg-room",
               discord_channel_id: "dc-room"
             )

    child = Enum.find(children, &(&1.id == Bridge))
    assert {Bridge, :start_link, [opts]} = child.start
    assert opts[:principal_id] == "explicit-actor"
  end

  defp stored_fact(id, origin) do
    {:ok, message} =
      Instance.save_message(%{
        id: id,
        room_id: "demo:lobby",
        sender_id: "sender",
        role: :user,
        content: [%{type: :text, text: "hello"}],
        metadata: %{channel: origin, username: "alice"}
      })

    {:ok, fact} = Events.room_event(Instance, :message_added, message.room_id, %{message: message})
    {message, fact}
  end

  defp await_subscribed(bridge) do
    Jido.Messaging.TestHelpers.assert_eventually(fn -> :sys.get_state(bridge).subscribed end, timeout: 1_000)
  end
end
