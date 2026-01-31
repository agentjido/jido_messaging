defmodule JidoMessaging.DeduperTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Deduper

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    TestMessaging.clear_dedupe()
    :ok
  end

  describe "check_and_mark/3" do
    test "returns :new for unseen keys" do
      assert :new = Deduper.check_and_mark(TestMessaging, {:test, "msg_1"})
    end

    test "returns :duplicate for previously seen keys" do
      key = {:test, "msg_2"}
      assert :new = Deduper.check_and_mark(TestMessaging, key)
      assert :duplicate = Deduper.check_and_mark(TestMessaging, key)
    end

    test "different keys are independent" do
      assert :new = Deduper.check_and_mark(TestMessaging, {:test, "a"})
      assert :new = Deduper.check_and_mark(TestMessaging, {:test, "b"})
      assert :duplicate = Deduper.check_and_mark(TestMessaging, {:test, "a"})
    end

    test "complex keys work correctly" do
      key = {:telegram, "bot_123", "chat_456", 789}
      assert :new = Deduper.check_and_mark(TestMessaging, key)
      assert :duplicate = Deduper.check_and_mark(TestMessaging, key)
    end
  end

  describe "seen?/2" do
    test "returns false for unseen keys" do
      refute Deduper.seen?(TestMessaging, {:unseen, "key"})
    end

    test "returns true for seen keys" do
      key = {:seen, "key"}
      Deduper.mark_seen(TestMessaging, key)
      assert Deduper.seen?(TestMessaging, key)
    end
  end

  describe "mark_seen/3" do
    test "marks a key as seen" do
      key = {:mark, "test"}
      refute Deduper.seen?(TestMessaging, key)
      assert :ok = Deduper.mark_seen(TestMessaging, key)
      assert Deduper.seen?(TestMessaging, key)
    end
  end

  describe "clear/1" do
    test "removes all keys" do
      Deduper.mark_seen(TestMessaging, {:clear, "1"})
      Deduper.mark_seen(TestMessaging, {:clear, "2"})

      assert Deduper.count(TestMessaging) == 2

      Deduper.clear(TestMessaging)

      assert Deduper.count(TestMessaging) == 0
      refute Deduper.seen?(TestMessaging, {:clear, "1"})
    end
  end

  describe "count/1" do
    test "returns number of tracked keys" do
      assert Deduper.count(TestMessaging) == 0

      Deduper.mark_seen(TestMessaging, {:count, "1"})
      assert Deduper.count(TestMessaging) == 1

      Deduper.mark_seen(TestMessaging, {:count, "2"})
      assert Deduper.count(TestMessaging) == 2
    end
  end

  describe "TTL expiration" do
    test "keys expire after TTL" do
      key = {:expire, "test"}
      # Use minimal TTL to speed up test
      ttl_ms = 20

      assert :new = Deduper.check_and_mark(TestMessaging, key, ttl_ms)
      assert :duplicate = Deduper.check_and_mark(TestMessaging, key, ttl_ms)

      # Wait for TTL expiration - this sleep is necessary for time-based testing
      Process.sleep(ttl_ms + 10)

      assert :new = Deduper.check_and_mark(TestMessaging, key, ttl_ms)
    end
  end
end
