defmodule JidoMessaging.AgentRunnerTest do
  use ExUnit.Case, async: true

  import JidoMessaging.TestHelpers

  alias JidoMessaging.{
    Room,
    Message,
    RoomServer,
    RoomSupervisor,
    AgentRunner,
    AgentSupervisor
  }

  defmodule TestMessaging do
    use JidoMessaging, adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "AgentRunner lifecycle" do
    test "starts an agent runner via supervisor" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "TestBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      assert {:ok, pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "test_bot", agent_config)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "stops an agent runner" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "TestBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      {:ok, pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "test_bot", agent_config)
      ref = Process.monitor(pid)

      assert :ok = AgentSupervisor.stop_agent(TestMessaging, room.id, "test_bot")

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      # Registry cleanup may lag slightly behind process termination
      assert_eventually(fn -> AgentRunner.whereis(TestMessaging, room.id, "test_bot") == nil end)
    end

    test "stop_agent returns error when agent not found" do
      assert {:error, :not_found} = AgentSupervisor.stop_agent(TestMessaging, "nonexistent", "bot")
    end

    test "whereis returns pid for running agent" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "TestBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      {:ok, pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "test_bot", agent_config)
      assert AgentRunner.whereis(TestMessaging, room.id, "test_bot") == pid
    end

    test "whereis returns nil for non-running agent" do
      assert nil == AgentRunner.whereis(TestMessaging, "nonexistent_room", "nonexistent_agent")
    end

    test "list_agents returns agents in room" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config1 = %{name: "Bot1", trigger: :all, handler: fn _, _ -> :noreply end}
      config2 = %{name: "Bot2", trigger: :all, handler: fn _, _ -> :noreply end}

      {:ok, pid1} = AgentSupervisor.start_agent(TestMessaging, room.id, "bot1", config1)
      {:ok, pid2} = AgentSupervisor.start_agent(TestMessaging, room.id, "bot2", config2)

      agents = AgentSupervisor.list_agents(TestMessaging, room.id)
      assert length(agents) == 2
      assert {"bot1", pid1} in agents
      assert {"bot2", pid2} in agents
    end

    test "count_agents returns correct count" do
      assert AgentSupervisor.count_agents(TestMessaging) == 0

      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config = %{name: "TestBot", trigger: :all, handler: fn _, _ -> :noreply end}

      {:ok, _} = AgentSupervisor.start_agent(TestMessaging, room.id, "bot1", config)
      assert AgentSupervisor.count_agents(TestMessaging) == 1

      {:ok, _} = AgentSupervisor.start_agent(TestMessaging, room.id, "bot2", config)
      assert AgentSupervisor.count_agents(TestMessaging) == 2
    end
  end

  describe "message processing with trigger :all" do
    test "agent processes all messages" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "EchoBot",
        trigger: :all,
        handler: fn message, _context ->
          send(test_pid, {:received, message.id})
          :noreply
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "echo_bot", agent_config)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      RoomServer.add_message(room_pid, message)

      assert_receive {:received, message_id}, 1000
      assert message_id == message.id
    end

    test "agent does not process its own messages" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "EchoBot",
        trigger: :all,
        handler: fn message, _context ->
          send(test_pid, {:received, message.id})
          :noreply
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "echo_bot", agent_config)

      own_message =
        Message.new(%{
          room_id: room.id,
          sender_id: "echo_bot",
          role: :assistant,
          content: [%{type: :text, text: "My own message"}]
        })

      RoomServer.add_message(room_pid, own_message)

      refute_receive {:received, _}, 100
    end
  end

  describe "message processing with trigger :mention" do
    test "agent processes messages that mention it" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "HelpBot",
        trigger: :mention,
        handler: fn message, _context ->
          send(test_pid, {:mentioned, message.id})
          :noreply
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "help_bot", agent_config)

      message_with_mention =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hey @HelpBot can you help?"}]
        })

      RoomServer.add_message(room_pid, message_with_mention)

      assert_receive {:mentioned, _}, 1000
    end

    test "agent ignores messages without mention" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "HelpBot",
        trigger: :mention,
        handler: fn message, _context ->
          send(test_pid, {:mentioned, message.id})
          :noreply
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "help_bot", agent_config)

      message_without_mention =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Just a regular message"}]
        })

      RoomServer.add_message(room_pid, message_without_mention)

      refute_receive {:mentioned, _}, 100
    end
  end

  describe "message processing with trigger {:prefix, prefix}" do
    test "agent processes messages with matching prefix" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "CmdBot",
        trigger: {:prefix, "/cmd"},
        handler: fn message, _context ->
          send(test_pid, {:command, message.id})
          :noreply
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "cmd_bot", agent_config)

      message_with_prefix =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "/cmd do something"}]
        })

      RoomServer.add_message(room_pid, message_with_prefix)

      assert_receive {:command, _}, 1000
    end

    test "agent ignores messages without matching prefix" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "CmdBot",
        trigger: {:prefix, "/cmd"},
        handler: fn message, _context ->
          send(test_pid, {:command, message.id})
          :noreply
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "cmd_bot", agent_config)

      message_without_prefix =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "No prefix here"}]
        })

      RoomServer.add_message(room_pid, message_without_prefix)

      refute_receive {:command, _}, 100
    end
  end

  describe "reply generation and delivery" do
    test "agent sends reply when handler returns {:reply, text}" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "EchoBot",
        trigger: :all,
        handler: fn message, _context ->
          text =
            message.content
            |> Enum.filter(&Map.has_key?(&1, :text))
            |> Enum.map(& &1.text)
            |> Enum.join(" ")

          {:reply, "Echo: #{text}"}
        end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "echo_bot", agent_config)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      RoomServer.add_message(room_pid, message)

      assert_eventually(
        fn ->
          messages = RoomServer.get_messages(room_pid)
          length(messages) == 2
        end,
        timeout: 500
      )

      messages = RoomServer.get_messages(room_pid)
      [reply, original] = messages
      assert original.id == message.id
      assert reply.sender_id == "echo_bot"
      assert reply.role == :assistant
      assert reply.reply_to_id == message.id

      [content | _] = reply.content
      assert content.text == "Echo: Hello!"
    end

    test "agent does not send reply when handler returns :noreply" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "SilentBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "silent_bot", agent_config)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      RoomServer.add_message(room_pid, message)

      # Give the agent time to process (it should not reply)
      # We wait briefly and verify no additional messages appeared
      assert_eventually(
        fn ->
          # Agent should have processed by now, verify only 1 message
          messages = RoomServer.get_messages(room_pid)
          length(messages) == 1
        end,
        timeout: 200
      )
    end
  end

  describe "agent appears as participant" do
    test "agent is added as participant when started" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "TestBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      {:ok, _agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "test_bot", agent_config)

      participants = RoomServer.get_participants(room_pid)
      assert length(participants) == 1

      [participant] = participants
      assert participant.id == "test_bot"
      assert participant.type == :agent
      assert participant.identity.name == "TestBot"
      assert participant.presence == :online
    end
  end

  describe "delegated functions in instance module" do
    test "add_agent_to_room delegates to AgentSupervisor" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config = %{name: "TestBot", trigger: :all, handler: fn _, _ -> :noreply end}

      assert {:ok, pid} = TestMessaging.add_agent_to_room(room.id, "test_bot", config)
      assert is_pid(pid)
    end

    test "remove_agent_from_room delegates to AgentSupervisor" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config = %{name: "TestBot", trigger: :all, handler: fn _, _ -> :noreply end}
      {:ok, _pid} = TestMessaging.add_agent_to_room(room.id, "test_bot", config)

      assert :ok = TestMessaging.remove_agent_from_room(room.id, "test_bot")
    end

    test "list_agents_in_room delegates to AgentSupervisor" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config = %{name: "TestBot", trigger: :all, handler: fn _, _ -> :noreply end}
      {:ok, pid} = TestMessaging.add_agent_to_room(room.id, "test_bot", config)

      agents = TestMessaging.list_agents_in_room(room.id)
      assert {"test_bot", pid} in agents
    end

    test "whereis_agent delegates to AgentRunner" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config = %{name: "TestBot", trigger: :all, handler: fn _, _ -> :noreply end}
      {:ok, pid} = TestMessaging.add_agent_to_room(room.id, "test_bot", config)

      assert TestMessaging.whereis_agent(room.id, "test_bot") == pid
    end

    test "count_agents delegates to AgentSupervisor" do
      assert TestMessaging.count_agents() == 0

      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config = %{name: "TestBot", trigger: :all, handler: fn _, _ -> :noreply end}
      {:ok, _pid} = TestMessaging.add_agent_to_room(room.id, "test_bot", config)

      assert TestMessaging.count_agents() == 1
    end

    test "__jido_messaging__ returns agent registry and supervisor names" do
      assert TestMessaging.__jido_messaging__(:agent_registry) ==
               Module.concat(TestMessaging, Registry.Agents)

      assert TestMessaging.__jido_messaging__(:agent_supervisor) ==
               Module.concat(TestMessaging, :AgentSupervisor)
    end
  end

  describe "RoomServer.get_agent_pids/2" do
    test "returns list of agent PIDs for a room" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      config1 = %{name: "Bot1", trigger: :all, handler: fn _, _ -> :noreply end}
      config2 = %{name: "Bot2", trigger: :all, handler: fn _, _ -> :noreply end}

      {:ok, pid1} = AgentSupervisor.start_agent(TestMessaging, room.id, "bot1", config1)
      {:ok, pid2} = AgentSupervisor.start_agent(TestMessaging, room.id, "bot2", config2)

      pids = RoomServer.get_agent_pids(TestMessaging, room.id)
      assert length(pids) == 2
      assert pid1 in pids
      assert pid2 in pids
    end

    test "returns empty list when no agents in room" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      assert RoomServer.get_agent_pids(TestMessaging, room.id) == []
    end
  end
end
