defmodule Jido.Messaging.MsgContext.CommandParserTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.MsgContext.CommandParser

  describe "parse/2" do
    test "parses prefixed commands deterministically" do
      text = "  /Deploy now please"

      assert %{
               status: :ok,
               source: :body,
               prefix: "/",
               name: "deploy",
               args: "now please",
               argv: ["now", "please"],
               reason: nil,
               text_bytes: bytes
             } = CommandParser.parse(text)

      assert bytes == byte_size(text)
    end

    test "returns typed error for malformed command names" do
      assert %{status: :error, reason: :invalid_command_name, prefix: "/"} =
               CommandParser.parse("/bad$name")
    end

    test "returns typed error when command name is missing" do
      assert %{status: :error, reason: :missing_command_name, prefix: "/"} =
               CommandParser.parse("/")
    end

    test "returns typed none envelope for non-command input" do
      assert %{status: :none, reason: :not_command} = CommandParser.parse("hello world")
    end

    test "fails safely for overlong text with bounded evaluation" do
      text = "/" <> String.duplicate("a", 200_000)
      started_at = System.monotonic_time(:millisecond)

      assert %{status: :error, reason: :text_too_long, text_bytes: bytes} =
               CommandParser.parse(text, max_text_bytes: 128)

      assert bytes == byte_size(text)
      assert System.monotonic_time(:millisecond) - started_at < 150
    end
  end

  describe "normalize_prefixes/1" do
    test "normalizes deduplicates and sorts by specificity" do
      assert CommandParser.normalize_prefixes(["/", "//", "/", "  !  "]) == ["//", "!", "/"]
    end
  end
end
