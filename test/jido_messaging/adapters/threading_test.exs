defmodule JidoMessaging.Adapters.ThreadingTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Adapters.Threading

  defmodule ChannelWithThreading do
    @behaviour JidoMessaging.Adapters.Threading

    @impl true
    def supports_threads?, do: true

    @impl true
    def compute_thread_root(raw) do
      raw["thread_ts"] || raw["ts"]
    end

    @impl true
    def extract_thread_context(raw) do
      %{
        thread_id: raw["thread_ts"],
        is_thread_reply: raw["thread_ts"] != nil,
        thread_root_ts: raw["thread_ts"] || raw["ts"]
      }
    end
  end

  defmodule ChannelWithoutThreading do
    @behaviour JidoMessaging.Adapters.Threading

    @impl true
    def supports_threads?, do: false

    @impl true
    def compute_thread_root(_raw), do: nil

    @impl true
    def extract_thread_context(_raw), do: %{}
  end

  defmodule ChannelWithPartialImplementation do
    @behaviour JidoMessaging.Adapters.Threading

    @impl true
    def supports_threads?, do: true
  end

  defmodule ChannelWithNoThreadingCallbacks do
    def some_other_function, do: :ok
  end

  describe "supports_threads?/1" do
    test "returns true for channel that supports threading" do
      assert Threading.supports_threads?(ChannelWithThreading) == true
    end

    test "returns false for channel that doesn't support threading" do
      assert Threading.supports_threads?(ChannelWithoutThreading) == false
    end

    test "returns false for channel without the callback" do
      assert Threading.supports_threads?(ChannelWithNoThreadingCallbacks) == false
    end

    test "returns true for channel with partial implementation" do
      assert Threading.supports_threads?(ChannelWithPartialImplementation) == true
    end
  end

  describe "compute_thread_root/2" do
    test "returns thread root from channel that implements it" do
      raw = %{"thread_ts" => "1234.5678", "ts" => "1234.0000"}

      result = Threading.compute_thread_root(ChannelWithThreading, raw)

      assert result == "1234.5678"
    end

    test "returns ts when no thread_ts present" do
      raw = %{"ts" => "1234.0000"}

      result = Threading.compute_thread_root(ChannelWithThreading, raw)

      assert result == "1234.0000"
    end

    test "returns nil from channel that doesn't support threading" do
      raw = %{"thread_ts" => "1234.5678"}

      result = Threading.compute_thread_root(ChannelWithoutThreading, raw)

      assert result == nil
    end

    test "returns nil for channel without the callback" do
      raw = %{"thread_ts" => "1234.5678"}

      result = Threading.compute_thread_root(ChannelWithNoThreadingCallbacks, raw)

      assert result == nil
    end

    test "returns nil for channel with partial implementation" do
      raw = %{"thread_ts" => "1234.5678"}

      result = Threading.compute_thread_root(ChannelWithPartialImplementation, raw)

      assert result == nil
    end
  end

  describe "extract_thread_context/2" do
    test "extracts context from channel that implements it" do
      raw = %{"thread_ts" => "1234.5678", "ts" => "1234.0000"}

      result = Threading.extract_thread_context(ChannelWithThreading, raw)

      assert result == %{
               thread_id: "1234.5678",
               is_thread_reply: true,
               thread_root_ts: "1234.5678"
             }
    end

    test "extracts context for non-threaded message" do
      raw = %{"ts" => "1234.0000"}

      result = Threading.extract_thread_context(ChannelWithThreading, raw)

      assert result == %{
               thread_id: nil,
               is_thread_reply: false,
               thread_root_ts: "1234.0000"
             }
    end

    test "returns empty map from channel that doesn't support threading" do
      raw = %{"thread_ts" => "1234.5678"}

      result = Threading.extract_thread_context(ChannelWithoutThreading, raw)

      assert result == %{}
    end

    test "returns empty map for channel without the callback" do
      raw = %{"thread_ts" => "1234.5678"}

      result = Threading.extract_thread_context(ChannelWithNoThreadingCallbacks, raw)

      assert result == %{}
    end

    test "returns empty map for channel with partial implementation" do
      raw = %{"thread_ts" => "1234.5678"}

      result = Threading.extract_thread_context(ChannelWithPartialImplementation, raw)

      assert result == %{}
    end
  end
end
