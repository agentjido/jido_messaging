defmodule Jido.Messaging.ChatActionsTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{Message, MessagePage, MessagingTarget, Response, Thread, ThreadPage}
  alias Jido.Messaging.ChatActions
  alias Jido.Messaging.ChatActions.{Policy, Scope}
  alias Jido.Messaging.ChatActions.Reader.{FetchChannelMessages, FetchMessage, FetchThreadMessages}
  alias Jido.Messaging.ChatActions.Messenger.{PostMessage, SendDirectMessage}
  alias Jido.Messaging.ChatActions.Moderator.{DeleteMessage, EnsureSubscription}

  defmodule FullAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :full

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def capabilities do
      %{
        send_message: :native,
        post_message: :native,
        post_channel_message: :native,
        edit_message: :native,
        delete_message: :native,
        start_typing: :native,
        fetch_metadata: :native,
        fetch_thread: :native,
        fetch_message: :native,
        add_reaction: :native,
        remove_reaction: :native,
        open_dm: :native,
        fetch_messages: :native,
        fetch_channel_messages: :native,
        list_threads: :native
      }
    end

    @impl true
    def send_message(room_id, text, opts) do
      record(:send_message, [room_id, text, opts])
      {:ok, %{external_message_id: "sent-1", external_room_id: room_id}}
    end

    @impl true
    def post_message(room_id, payload, opts) do
      record(:post_message, [room_id, payload, opts])
      {:ok, %{external_message_id: "post-1", external_room_id: room_id}}
    end

    @impl true
    def post_channel_message(room_id, text, opts) do
      record(:post_channel_message, [room_id, text, opts])
      {:ok, %{external_message_id: "channel-post-1", external_room_id: room_id}}
    end

    @impl true
    def edit_message(room_id, message_id, text, opts) do
      record(:edit_message, [room_id, message_id, text, opts])
      {:ok, %{external_message_id: message_id, external_room_id: room_id}}
    end

    @impl true
    def delete_message(room_id, message_id, opts) do
      record(:delete_message, [room_id, message_id, opts])
      :ok
    end

    @impl true
    def start_typing(room_id, opts) do
      record(:start_typing, [room_id, opts])
      :ok
    end

    @impl true
    def fetch_metadata(room_id, opts) do
      record(:fetch_metadata, [room_id, opts])
      {:ok, %{id: to_string(room_id), name: "Full room"}}
    end

    @impl true
    def fetch_thread(room_id, opts) do
      record(:fetch_thread, [room_id, opts])

      {:ok,
       %{
         id: "full:#{room_id}:#{opts[:external_thread_id]}",
         adapter_name: :full,
         adapter: __MODULE__,
         external_room_id: room_id,
         external_thread_id: opts[:external_thread_id]
       }}
    end

    @impl true
    def fetch_message(room_id, message_id, opts) do
      record(:fetch_message, [room_id, message_id, opts])

      case message_id do
        "credential-error" ->
          {:error, {:api_error, %{access_token: "provider-secret-token"}}}

        "sibling-message" ->
          {:ok,
           %{
             external_message_id: message_id,
             external_room_id: room_id,
             external_thread_id: "thread-2",
             text: "sibling"
           }}

        "thread-message" ->
          {:ok,
           %{
             external_message_id: message_id,
             external_room_id: room_id,
             external_thread_id: "thread-1",
             text: "thread"
           }}

        _other ->
          {:ok, %{external_message_id: to_string(message_id), external_room_id: room_id, text: "hello"}}
      end
    end

    @impl true
    def fetch_messages(room_id, opts) do
      record(:fetch_messages, [room_id, opts])
      {:ok, %{messages: [%{id: "thread-1", external_room_id: room_id, text: "thread"}]}}
    end

    @impl true
    def fetch_channel_messages(room_id, opts) do
      record(:fetch_channel_messages, [room_id, opts])
      {:ok, %{messages: [%{id: "channel-1", external_room_id: room_id, text: "channel"}]}}
    end

    @impl true
    def list_threads(room_id, opts) do
      record(:list_threads, [room_id, opts])
      {:ok, %{threads: [%{id: "thread-1"}]}}
    end

    @impl true
    def open_dm(user_id, opts) do
      record(:open_dm, [user_id, opts])
      {:ok, "dm-#{user_id}"}
    end

    @impl true
    def add_reaction(room_id, message_id, emoji, opts) do
      record(:add_reaction, [room_id, message_id, emoji, opts])
      :ok
    end

    @impl true
    def remove_reaction(room_id, message_id, emoji, opts) do
      record(:remove_reaction, [room_id, message_id, emoji, opts])
      :ok
    end

    def ensure_ingress_subscription(bridge_id, opts) do
      record(:ensure_ingress_subscription, [bridge_id, opts])
      {:ok, %{id: "sub-1", target_url: "https://example.test/hook"}}
    end

    def list_ingress_subscriptions(bridge_id, opts) do
      record(:list_ingress_subscriptions, [bridge_id, opts])
      {:ok, [%{id: "sub-1"}]}
    end

    def delete_ingress_subscription(bridge_id, subscription_id, opts) do
      record(:delete_ingress_subscription, [bridge_id, subscription_id, opts])
      {:ok, %{id: subscription_id}}
    end

    def lookup_user(query, opts) do
      record(:lookup_user, [query, opts])
      {:ok, %{id: query[:id], name: "Ada"}}
    end

    defp record(operation, args) do
      if pid = Application.get_env(:jido_messaging, :chat_actions_test_pid) do
        send(pid, {:provider_call, __MODULE__, operation, args})
      end
    end
  end

  defmodule ReadOnlyAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :read_only

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def capabilities, do: %{send_message: :native, fetch_message: :native}

    @impl true
    def send_message(room_id, text, opts) do
      record(:send_message, [room_id, text, opts])
      {:ok, %{external_message_id: "read-send-1", external_room_id: room_id}}
    end

    @impl true
    def fetch_message(room_id, message_id, opts) do
      record(:fetch_message, [room_id, message_id, opts])
      {:ok, %{id: to_string(message_id), external_room_id: room_id, text: "read only"}}
    end

    defp record(operation, args) do
      if pid = Application.get_env(:jido_messaging, :chat_actions_test_pid) do
        send(pid, {:provider_call, __MODULE__, operation, args})
      end
    end
  end

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    Application.put_env(:jido_messaging, :chat_actions_test_pid, self())
    start_supervised!(TestMessaging)

    {:ok, _} =
      TestMessaging.put_bridge_config(%{
        id: "full-main",
        adapter_module: FullAdapter,
        opts: %{
          workspace_id: "workspace-1",
          ingress: %{target_url: "https://trusted.example.test/hook"}
        }
      })

    {:ok, _} =
      TestMessaging.put_bridge_config(%{
        id: "read-main",
        adapter_module: ReadOnlyAdapter,
        opts: %{workspace_id: "workspace-1"}
      })

    on_exit(fn -> Application.delete_env(:jido_messaging, :chat_actions_test_pid) end)
    :ok
  end

  describe "capability-first action sets" do
    test "builds presets and custom lists from two adapters" do
      full = target("full-main", :full, "room-1")
      read_only = target("read-main", :read_only, "room-1")

      assert {:ok, full_reader} = ChatActions.actions_for(TestMessaging, full, :reader)
      assert FetchMessage in full_reader
      assert FetchChannelMessages in full_reader

      assert {:ok, full_actions} = ChatActions.actions_for(TestMessaging, full, :all)
      assert length(full_actions) == length(ChatActions.preset(:all))

      for action <- ChatActions.preset(:all), prohibited <- [:credentials, :adapter_module, :client] do
        refute Keyword.has_key?(action.schema().fields, prohibited)

        target_schema = Keyword.fetch!(action.schema().fields, :target)
        refute Keyword.has_key?(target_schema.fields, prohibited)
      end

      assert {:ok, read_only_reader} = ChatActions.actions_for(TestMessaging, read_only, :reader)
      assert FetchMessage in read_only_reader
      refute FetchChannelMessages in read_only_reader

      assert {:ok, read_only_messenger} = ChatActions.actions_for(TestMessaging, read_only, :messenger)
      assert PostMessage in read_only_messenger

      assert {:ok, [FetchMessage]} =
               ChatActions.actions_for(TestMessaging, read_only, [FetchMessage, DeleteMessage])
    end

    test "rejects unsupported work before a provider call" do
      context = action_context(channel_scope("read-main", :read_only, "room-1"))

      assert {:ok, %{status: :error, code: :unsupported_operation}} =
               Jido.Exec.run(
                 DeleteMessage,
                 %{target: target_map("read-main", :read_only, "room-1"), message_id: "m-1"},
                 context
               )

      refute_receive {:provider_call, ReadOnlyAdapter, :delete_message, _}
    end
  end

  describe "reader operations and scope" do
    test "returns canonical normalized models from adapter reads" do
      context = action_context(channel_scope("full-main", :full, "room-1"))

      assert {:ok, %{status: :ok, data: %Message{id: "m-1"}}} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target_map("full-main", :full, "room-1"), message_id: "m-1"},
                 context
               )

      assert_receive {:provider_call, FullAdapter, :fetch_message, ["room-1", "m-1", opts]}
      assert opts[:credentials] == %{}
      refute Keyword.has_key?(FetchMessage.schema().fields, :credentials)

      assert {:ok, %{status: :ok, data: %MessagePage{}}} =
               Jido.Exec.run(FetchChannelMessages, %{target: target_map("full-main", :full, "room-1")}, context)
    end

    test "blocks cross-channel and spoofed adapter reads before provider access" do
      context = action_context(channel_scope("full-main", :full, "room-1"))

      assert {:ok, %{status: :denied, code: :out_of_scope}} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target_map("full-main", :full, "room-2"), message_id: "m-1"},
                 context
               )

      assert {:ok, %{status: :error, code: :target_mismatch}} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target_map("full-main", :read_only, "room-1"), message_id: "m-1"},
                 context
               )

      refute_receive {:provider_call, _, :fetch_message, _}
    end

    test "strict thread rejects a sibling thread and its parent channel" do
      scope = Scope.strict_thread("full-main", :full, "room-1", "thread-1", actor_id: "actor-1")
      context = action_context(scope)

      assert {:ok, %{status: :denied, code: :out_of_scope}} =
               Jido.Exec.run(
                 FetchThreadMessages,
                 %{target: target_map("full-main", :full, "room-1", "thread-2")},
                 context
               )

      assert {:ok, %{status: :denied, code: :out_of_scope}} =
               Jido.Exec.run(FetchChannelMessages, %{target: target_map("full-main", :full, "room-1")}, context)

      refute_receive {:provider_call, FullAdapter, _, _}
    end

    test "strict thread rejects channel-only work even when the target carries its thread" do
      scope = Scope.strict_thread("full-main", :full, "room-1", "thread-1", actor_id: "actor-1")
      policy = Policy.allow([:post_channel_message], actor: "actor-1", channel: "room-1")
      context = action_context(scope, policy)
      target = target_map("full-main", :full, "room-1", "thread-1")

      assert {:ok, %{status: :denied, code: :out_of_scope}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Messenger.PostChannelMessage,
                 %{target: target, text: "escape"},
                 context
               )

      refute_receive {:provider_call, FullAdapter, :post_channel_message, _}
    end

    test "strict thread verifies message membership before reads and mutations" do
      operations = [
        {FetchMessage, :fetch_message, %{message_id: "sibling-message"}},
        {Jido.Messaging.ChatActions.Moderator.EditMessage, :edit_message,
         %{message_id: "sibling-message", text: "edited"}},
        {DeleteMessage, :delete_message, %{message_id: "sibling-message"}},
        {Jido.Messaging.ChatActions.Moderator.AddReaction, :add_reaction,
         %{message_id: "sibling-message", emoji: "ok"}},
        {Jido.Messaging.ChatActions.Moderator.RemoveReaction, :remove_reaction,
         %{message_id: "sibling-message", emoji: "ok"}}
      ]

      action_names = Enum.map(operations, fn {_module, action, _params} -> action end)
      scope = Scope.strict_thread("full-main", :full, "room-1", "thread-1", actor_id: "actor-1")
      policy = Policy.allow(action_names, actor: "actor-1", channel: "room-1", thread: "thread-1")
      context = action_context(scope, policy)
      target = target_map("full-main", :full, "room-1", "thread-1")

      for {action, provider_operation, params} <- operations do
        assert {:ok, %{status: :denied, code: :out_of_scope}} =
                 Jido.Exec.run(action, Map.put(params, :target, target), context)

        assert_receive {:provider_call, FullAdapter, :fetch_message, ["room-1", "sibling-message", opts]}
        refute Keyword.has_key?(opts, :thread_id)
        refute Keyword.has_key?(opts, :external_thread_id)

        if provider_operation != :fetch_message do
          refute_receive {:provider_call, FullAdapter, ^provider_operation, _}
        end
      end

      assert {:ok, %{status: :ok, data: %Message{id: "thread-message"}}} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target, message_id: "thread-message"},
                 context
               )

      assert_receive {:provider_call, FullAdapter, :fetch_message, ["room-1", "thread-message", _opts]}
      refute_receive {:provider_call, FullAdapter, :fetch_message, ["room-1", "thread-message", _opts]}

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Moderator.EditMessage,
                 %{target: target, message_id: "thread-message", text: "edited"},
                 context
               )

      assert_receive {:provider_call, FullAdapter, :fetch_message, ["room-1", "thread-message", verify_opts]}
      refute Keyword.has_key?(verify_opts, :thread_id)

      assert_receive {:provider_call, FullAdapter, :edit_message, ["room-1", "thread-message", "edited", mutation_opts]}

      assert mutation_opts[:thread_id] == "thread-1"
      assert mutation_opts[:external_thread_id] == "thread-1"
    end

    test "participant lookup cannot replace the trusted adapter selector" do
      {:ok, participant} =
        TestMessaging.create_participant(%{
          id: "participant-trusted-adapter",
          type: :human,
          identity: %{name: "Trusted Ada"},
          external_ids: %{full: "trusted-user"}
        })

      context = action_context(channel_scope("full-main", :full, "room-1"))

      assert {:ok, %{status: :ok, data: ^participant}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Reader.LookupParticipant,
                 %{
                   target: target_map("full-main", :full, "room-1"),
                   query: %{external_id: "trusted-user", channel: :read_only}
                 },
                 context
               )
    end

    test "provider errors do not expose provider credentials" do
      context = action_context(channel_scope("full-main", :full, "room-1"))

      assert {:ok, %{status: :error, code: :provider_error, details: %{reason: %{type: :api_error}}} = result} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target_map("full-main", :full, "room-1"), message_id: "credential-error"},
                 context
               )

      refute inspect(result) =~ "provider-secret-token"
    end

    test "workspace reads require an explicit workspace scope" do
      implicit = Scope.from_map(%{kind: :workspace, workspace_id: "workspace-1", explicit: false})
      context = action_context(implicit)

      assert {:ok, %{status: :denied, code: :workspace_scope_not_explicit}} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target_map("full-main", :full, "room-1"), message_id: "m-1"},
                 context
               )

      explicit = Scope.workspace("workspace-1", actor_id: "actor-1")

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 FetchMessage,
                 %{target: target_map("full-main", :full, "room-1"), message_id: "m-1"},
                 action_context(explicit)
               )
    end

    test "inherits a thread scope from active normalized context" do
      active_context = %{
        bridge_id: "full-main",
        channel_type: :full,
        external_room_id: "room-1",
        external_thread_id: "thread-1",
        external_user_id: "actor-1"
      }

      context = ChatActions.context(TestMessaging, active_context)

      assert {:ok, %{status: :ok, audit: %{scope_kind: :thread, actor_id: "actor-1"}}} =
               Jido.Exec.run(
                 FetchThreadMessages,
                 %{target: target_map("full-main", :full, "room-1", "thread-1")},
                 context
               )
    end

    test "executes the remaining reader seams with normalized results" do
      {:ok, participant} =
        TestMessaging.create_participant(%{
          id: "participant-1",
          type: :human,
          identity: %{name: "Ada"},
          external_ids: %{full: "user-1"}
        })

      context = action_context(channel_scope("full-main", :full, "room-1"))
      thread_target = target_map("full-main", :full, "room-1", "thread-1")
      room_target = target_map("full-main", :full, "room-1")

      assert {:ok, %{status: :ok, data: %Thread{external_thread_id: "thread-1"}}} =
               Jido.Exec.run(Jido.Messaging.ChatActions.Reader.FetchThread, %{target: thread_target}, context)

      assert {:ok, %{status: :ok, data: %MessagePage{}}} =
               Jido.Exec.run(FetchThreadMessages, %{target: thread_target}, context)

      assert {:ok, %{status: :ok, data: %ThreadPage{}}} =
               Jido.Exec.run(Jido.Messaging.ChatActions.Reader.ListThreads, %{target: room_target}, context)

      assert {:ok, %{status: :ok, data: ^participant}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Reader.LookupParticipant,
                 %{target: room_target, query: %{external_id: "user-1"}},
                 context
               )

      workspace_context = action_context(Scope.workspace("workspace-1", actor_id: "actor-1"))

      assert {:ok, %{status: :ok, data: %{id: "provider-user-1", name: "Ada"}}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Reader.LookupUser,
                 %{target: room_target, query: %{id: "provider-user-1"}},
                 workspace_context
               )

      assert {:ok, %{status: :ok, data: %Jido.Chat.ChannelInfo{id: "room-1"}}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Reader.FetchChannelMetadata,
                 %{target: room_target},
                 context
               )
    end
  end

  describe "write approval policy" do
    test "matches an adapter-scoped allow rule and uses the text post fallback" do
      policy =
        Policy.allow([:post_message],
          adapter: :read_only,
          actor: "actor-1",
          channel: "room-1"
        )

      context = action_context(channel_scope("read-main", :read_only, "room-1"), policy)

      assert {:ok, %{status: :ok, data: %Response{external_message_id: "read-send-1"}}} =
               Jido.Exec.run(
                 PostMessage,
                 %{target: target_map("read-main", :read_only, "room-1"), text: "fallback"},
                 context
               )

      assert_receive {:provider_call, ReadOnlyAdapter, :send_message, ["room-1", "fallback", _opts]}
    end

    test "visible writes need approval by default and return audit context" do
      context = action_context(channel_scope("full-main", :full, "room-1"))

      assert {:ok,
              %{
                status: :approval_required,
                code: :approval_required,
                audit: %{action: :post_message, actor_id: "actor-1", bridge_id: "full-main"}
              }} =
               Jido.Exec.run(PostMessage, %{target: target_map("full-main", :full, "room-1"), text: "hello"}, context)

      refute_receive {:provider_call, FullAdapter, :post_message, _}
    end

    test "allows only a narrow configured action and denies a matching action" do
      policy =
        Policy.new(%{
          rules: [
            %{
              result: :allow,
              actions: [:post_message],
              adapters: [:full],
              channels: ["room-1"],
              actors: ["actor-1"]
            },
            %{result: :deny, actions: [:delete_message], actors: ["actor-1"]}
          ]
        })

      context = action_context(channel_scope("full-main", :full, "room-1"), policy)

      assert {:ok, %{status: :ok, data: %Response{external_message_id: "post-1"}}} =
               Jido.Exec.run(PostMessage, %{target: target_map("full-main", :full, "room-1"), text: "hello"}, context)

      assert_receive {:provider_call, FullAdapter, :post_message, _}

      assert {:ok, %{status: :denied, code: :policy_denied}} =
               Jido.Exec.run(
                 DeleteMessage,
                 %{target: target_map("full-main", :full, "room-1"), message_id: "m-1"},
                 context
               )

      refute_receive {:provider_call, FullAdapter, :delete_message, _}
    end

    test "does not accept an actor identifier supplied by action parameters" do
      policy = Policy.allow([:post_message], actor: "privileged-actor", channel: "room-1")
      context = action_context(channel_scope("full-main", :full, "room-1"), policy)

      assert {:ok, %{status: :approval_required, audit: %{actor_id: "actor-1"}}} =
               Jido.Exec.run(
                 PostMessage,
                 %{
                   target: target_map("full-main", :full, "room-1"),
                   text: "spoof",
                   actor_id: "privileged-actor"
                 },
                 context
               )

      refute_receive {:provider_call, FullAdapter, :post_message, _}
    end

    test "uses one trusted actor when a supplied scope has a different actor" do
      scope = Scope.channel("full-main", :full, "room-1", actor_id: "privileged-actor")
      policy = Policy.allow([:post_message], actor: "privileged-actor", channel: "room-1")

      context =
        ChatActions.context(TestMessaging, %{scope: scope, policy: policy, actor_id: "actor-1"})

      assert context.chat_action.actor_id == "actor-1"
      assert context.chat_action.scope.actor_id == "actor-1"

      assert {:ok, %{status: :approval_required, audit: %{actor_id: "actor-1"}}} =
               Jido.Exec.run(
                 PostMessage,
                 %{target: target_map("full-main", :full, "room-1"), text: "blocked"},
                 context
               )

      refute_receive {:provider_call, FullAdapter, :post_message, _}
    end

    test "direct messages and subscription changes require explicit workspace and approval" do
      narrow_policy =
        Policy.new(%{
          rules: [
            %{result: :allow, actions: [:send_direct_message, :ensure_subscription], actors: ["actor-1"]}
          ]
        })

      channel_context = action_context(channel_scope("full-main", :full, "room-1"), narrow_policy)

      assert {:ok, %{status: :denied, code: :workspace_scope_required}} =
               Jido.Exec.run(
                 SendDirectMessage,
                 %{target: target_map("full-main", :full, "room-1"), user_id: "user-1", text: "secret"},
                 channel_context
               )

      workspace_context = action_context(Scope.workspace("workspace-1", actor_id: "actor-1"), narrow_policy)

      assert {:ok, %{status: :ok, data: %Response{external_room_id: "dm-user-1"}}} =
               Jido.Exec.run(
                 SendDirectMessage,
                 %{target: target_map("full-main", :full, "room-1"), user_id: "user-1", text: "secret"},
                 workspace_context
               )

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 EnsureSubscription,
                 %{
                   target: target_map("full-main", :full, "room-1"),
                   target_url: "https://attacker.example.test/hook"
                 },
                 workspace_context
               )

      refute Keyword.has_key?(EnsureSubscription.schema().fields, :target_url)

      assert_receive {:provider_call, FullAdapter, :ensure_ingress_subscription, ["full-main", subscription_opts]}
      assert subscription_opts[:target_url] == "https://trusted.example.test/hook"
    end

    test "executes edit, delete, reaction, typing, channel-post, and subscription operations" do
      actions = [
        :post_channel_message,
        :edit_message,
        :delete_message,
        :add_reaction,
        :remove_reaction,
        :delete_subscription
      ]

      policy = Policy.allow(actions, actor: "actor-1", channel: "room-1")
      channel_context = action_context(channel_scope("full-main", :full, "room-1"), policy)
      room_target = target_map("full-main", :full, "room-1")

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Messenger.PostChannelMessage,
                 %{target: room_target, text: "channel"},
                 channel_context
               )

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Moderator.EditMessage,
                 %{target: room_target, message_id: "m-1", text: "edited"},
                 channel_context
               )

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(DeleteMessage, %{target: room_target, message_id: "m-1"}, channel_context)

      for action <- [
            Jido.Messaging.ChatActions.Moderator.AddReaction,
            Jido.Messaging.ChatActions.Moderator.RemoveReaction
          ] do
        assert {:ok, %{status: :ok}} =
                 Jido.Exec.run(action, %{target: room_target, message_id: "m-1", emoji: "ok"}, channel_context)
      end

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Messenger.StartTyping,
                 %{target: room_target},
                 channel_context
               )

      workspace_policy =
        Policy.new(%{rules: [%{result: :allow, actions: [:delete_subscription], actors: ["actor-1"]}]})

      workspace_context = action_context(Scope.workspace("workspace-1", actor_id: "actor-1"), workspace_policy)

      assert {:ok, %{status: :ok, data: [_subscription]}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Moderator.ListSubscriptions,
                 %{target: room_target},
                 workspace_context
               )

      assert {:ok, %{status: :ok}} =
               Jido.Exec.run(
                 Jido.Messaging.ChatActions.Moderator.DeleteSubscription,
                 %{target: room_target, subscription_id: "sub-1"},
                 workspace_context
               )
    end
  end

  test "serializes scope and policy and preserves them through async action execution" do
    scope = Scope.thread("full-main", :full, "room-1", "thread-1", actor_id: "actor-1")
    policy = Policy.allow([:post_message], actor: "actor-1", channel: "room-1", thread: "thread-1")

    assert scope == scope |> Scope.to_map() |> Jason.encode!() |> Jason.decode!() |> Scope.from_map()
    assert policy == policy |> Policy.to_map() |> Jason.encode!() |> Jason.decode!() |> Policy.from_map()

    context = action_context(scope, policy)
    target = target_map("full-main", :full, "room-1", "thread-1")
    async_ref = Jido.Exec.run_async(PostMessage, %{target: target, text: "async"}, context)

    assert {:ok, %{status: :ok, audit: %{thread_id: "thread-1", actor_id: "actor-1"}}} =
             Jido.Exec.Async.await(async_ref)

    assert_receive {:provider_call, FullAdapter, :post_message, _}
  end

  defp action_context(scope, policy \\ Policy.default()) do
    ChatActions.context(TestMessaging, %{scope: scope, policy: policy, actor_id: "actor-1"})
  end

  defp channel_scope(bridge_id, adapter, channel_id) do
    Scope.channel(bridge_id, adapter, channel_id, actor_id: "actor-1")
  end

  defp target(bridge_id, channel_type, channel_id) do
    MessagingTarget.for_room(channel_id, bridge_id: bridge_id, channel_type: channel_type)
  end

  defp target_map(bridge_id, channel_type, channel_id, thread_id \\ nil) do
    target =
      if thread_id do
        MessagingTarget.for_thread(channel_id, thread_id,
          bridge_id: bridge_id,
          channel_type: channel_type
        )
      else
        target(bridge_id, channel_type, channel_id)
      end

    Map.from_struct(target)
  end
end
