defmodule Jido.Messaging.GatingTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{Gating, MsgContext}

  defmodule AllowAllGater do
    @behaviour Jido.Messaging.Gating

    @impl true
    def check(_ctx, _opts), do: :allow
  end

  defmodule DenyAllGater do
    @behaviour Jido.Messaging.Gating

    @impl true
    def check(_ctx, _opts), do: {:deny, :denied, "Always denied"}
  end

  defmodule RequireMentionGater do
    @behaviour Jido.Messaging.Gating

    @impl true
    def check(%MsgContext{was_mentioned: true}, _opts), do: :allow
    def check(%MsgContext{chat_type: :direct}, _opts), do: :allow
    def check(_ctx, _opts), do: {:deny, :not_mentioned, "Bot was not mentioned"}
  end

  defmodule RequireGroupGater do
    @behaviour Jido.Messaging.Gating

    @impl true
    def check(%MsgContext{chat_type: :group}, _opts), do: :allow
    def check(_ctx, _opts), do: {:deny, :not_group, "Only allowed in groups"}
  end

  defmodule OptsCheckingGater do
    @behaviour Jido.Messaging.Gating

    @impl true
    def check(_ctx, opts) do
      if Keyword.get(opts, :allow, false) do
        :allow
      else
        {:deny, :opts_deny, "Denied by opts"}
      end
    end
  end

  defp build_context(attrs \\ %{}) do
    base = %{
      channel_type: :telegram,
      bridge_id: "bot_123",
      external_room_id: "room_456",
      external_user_id: "user_789"
    }

    MsgContext
    |> struct!(Map.merge(base, attrs))
  end

  describe "run_checks/3" do
    test "returns :allow when no gaters are provided" do
      ctx = build_context()
      assert Gating.run_checks(ctx, []) == :allow
    end

    test "returns :allow when all gaters allow" do
      ctx = build_context()
      assert Gating.run_checks(ctx, [AllowAllGater, AllowAllGater]) == :allow
    end

    test "returns denial from first denying gater" do
      ctx = build_context()
      result = Gating.run_checks(ctx, [AllowAllGater, DenyAllGater, AllowAllGater])
      assert result == {:deny, :denied, "Always denied"}
    end

    test "stops at first denial" do
      ctx = build_context()
      result = Gating.run_checks(ctx, [DenyAllGater, AllowAllGater])
      assert result == {:deny, :denied, "Always denied"}
    end

    test "RequireMentionGater allows when mentioned" do
      ctx = build_context(%{was_mentioned: true, chat_type: :group})
      assert Gating.run_checks(ctx, [RequireMentionGater]) == :allow
    end

    test "RequireMentionGater allows in direct messages" do
      ctx = build_context(%{was_mentioned: false, chat_type: :direct})
      assert Gating.run_checks(ctx, [RequireMentionGater]) == :allow
    end

    test "RequireMentionGater denies in group without mention" do
      ctx = build_context(%{was_mentioned: false, chat_type: :group})

      assert Gating.run_checks(ctx, [RequireMentionGater]) ==
               {:deny, :not_mentioned, "Bot was not mentioned"}
    end

    test "multiple gaters can be chained" do
      ctx = build_context(%{was_mentioned: true, chat_type: :group})
      assert Gating.run_checks(ctx, [RequireMentionGater, RequireGroupGater]) == :allow
    end

    test "chained gaters stop at first denial" do
      ctx = build_context(%{was_mentioned: true, chat_type: :direct})

      result = Gating.run_checks(ctx, [RequireMentionGater, RequireGroupGater])
      assert result == {:deny, :not_group, "Only allowed in groups"}
    end

    test "opts are passed to gaters" do
      ctx = build_context()

      assert Gating.run_checks(ctx, [OptsCheckingGater], allow: true) == :allow

      assert Gating.run_checks(ctx, [OptsCheckingGater], allow: false) ==
               {:deny, :opts_deny, "Denied by opts"}
    end
  end

  describe "implements?/1" do
    test "returns true for modules implementing Gating behaviour" do
      assert Gating.implements?(AllowAllGater)
      assert Gating.implements?(DenyAllGater)
      assert Gating.implements?(RequireMentionGater)
    end

    test "returns false for modules not implementing Gating behaviour" do
      refute Gating.implements?(String)
      refute Gating.implements?(MsgContext)
    end
  end
end
