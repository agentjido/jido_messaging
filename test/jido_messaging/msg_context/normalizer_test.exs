defmodule Jido.Messaging.MsgContext.NormalizerTest do
  use ExUnit.Case, async: true
  alias Jido.Messaging.MsgContext
  alias Jido.Messaging.MsgContext.Normalizer

  defmodule Provider.Mentions do
    def parse_mentions(_adapter, body, raw) do
      send(self(), {:parsed, body, raw})
      [%{"user_id" => "bot", "username" => "Bot", "mention_text" => "<@bot>", "offset" => 0, "length" => 6}]
    end

    def was_mentioned?(_adapter, raw, target), do: raw[:target] == target
  end

  defmodule TwoArity.Mentions do
    def parse_mentions(body, raw) do
      send(self(), {:parsed_two, body, raw})
      [%{user_id: "bot", mention_text: "@bot", metadata: %{offset: 0, length: 4}}]
    end

    def was_mentioned?(raw, target), do: raw[:target] == target
  end

  defmodule CheckOnly.Mentions do
    def was_mentioned?(_adapter, raw, target), do: raw[:target] == target
  end

  defmodule Failures.Mentions do
    def parse_mentions(_adapter, _body, raw), do: fail(raw[:mode])
    def was_mentioned?(_adapter, raw, _target), do: fail(raw[:mode])
    defp fail(:raise), do: raise("private-provider-detail")
    defp fail(:throw), do: throw(:private_provider_detail)
    defp fail(:exit), do: exit(:private_provider_detail)
  end

  defp context(body, module, extra \\ %{}) do
    base =
      MsgContext.from_incoming(Jido.Chat.AdapterTestKit.MockAdapter, "bot", %{
        external_room_id: "room",
        external_user_id: "user",
        text: body
      })

    struct!(base, Map.merge(%{channel_module: module, channel_type: :normalizer_fixture}, extra))
  end

  test "a private provider mention span selects the command after the platform mention" do
    base = context("<@bot>: /Deploy now @alpha @alpha", Provider)
    raw = %{target: "bot"}
    result = Normalizer.normalize(base, %{raw: raw}, mention_targets: [" BOT ", "", nil, "bot"])
    assert_receive {:parsed, "<@bot>: /Deploy now @alpha @alpha", ^raw}
    assert result.was_mentioned
    assert result.command.status == :ok
    assert result.command.name == "deploy"
    assert result.command.source == :mention_stripped
    assert result.agent_mentions == ["alpha"]
    assert hd(result.mentions).metadata == %{offset: 0, length: 6}
    assert base.body == result.body
  end

  test "the two-argument private helper keeps routing and the original command arguments" do
    result = Normalizer.normalize(context("@bot /Deploy one two", TwoArity), %{raw: %{target: "bot"}})
    assert_receive {:parsed_two, "@bot /Deploy one two", _}
    assert result.was_mentioned
    assert result.command.argv == ["one", "two"]
    assert result.command.source == :mention_stripped
  end

  test "a helper with only a mention check uses bounded text parsing" do
    result = Normalizer.normalize(context("@bot /deploy now", CheckOnly), %{raw: %{target: "bot"}})
    assert result.was_mentioned
    assert result.command.name == "deploy"
    assert hd(result.mentions).metadata == %{offset: 0, length: 4}
  end

  for mode <- [:raise, :throw, :exit] do
    test "provider parser #{mode} keeps Unicode byte spans and safe fallback mention data" do
      result = Normalizer.normalize(context("é @bot", Failures), %{raw: %{mode: unquote(mode)}})
      assert result.was_mentioned
      assert hd(result.mentions).metadata == %{offset: 3, length: 4}
      assert result.command.status == :none
    end

    test "provider mention check #{mode} cannot turn an unrelated message into a mention" do
      result = Normalizer.normalize(context("unrelated", Failures), %{raw: %{mode: unquote(mode)}})
      refute result.was_mentioned
      assert result.mentions == []
      assert result.agent_mentions == []
    end
  end

  test "a text-size limit prevents private parser calls but retains explicit provider mentions" do
    base = context("long message", Provider, %{was_mentioned: true, mentions: [%{user_id: "bot"}]})
    result = Normalizer.normalize(base, %{raw: []}, mentions_max_text_bytes: 4, command_max_text_bytes: 4)
    refute_received {:parsed, _, _}
    assert result.was_mentioned
    assert result.raw == %{}
    assert length(result.mentions) == 1
    assert result.command.reason == :text_too_long
    assert result.body == "long message"
  end

  test "invalid mention entries cannot replace the text or its valid command" do
    base =
      context("/deploy now", nil, %{
        mentions: [nil, "invalid", %{"username" => "bot", "metadata" => "invalid", "offset" => 100, "length" => 6}]
      })

    result = Normalizer.normalize(base, %{}, mention_targets: [])
    assert result.command.name == "deploy"
    assert result.command.source == :body
    assert result.body == "/deploy now"
    assert length(result.mentions) == 1
  end

  test "a malformed command after a valid leading mention remains a command error" do
    base = context("@bot /bad$name", nil, %{mentions: [%{username: "bot", mention_text: "@bot", offset: 0, length: 4}]})
    result = Normalizer.normalize(base, %{})
    assert result.command.status == :error
    assert result.command.reason == :invalid_command_name
    assert result.command.source == :mention_stripped
  end

  test "a mention span that cuts a Unicode code point does not crash or remove text" do
    base = context("é /deploy", nil, %{mentions: [%{user_id: "bot", offset: 0, length: 1}]})
    result = Normalizer.normalize(base, %{})
    assert result.body == "é /deploy"
    assert result.command.status == :none
  end

  test "invalid limits use the bounded defaults and keep a valid command" do
    result =
      Normalizer.normalize(context("@bot /deploy", TwoArity), %{},
        command_max_text_bytes: 0,
        mentions_max_text_bytes: nil
      )

    assert result.command.name == "deploy"
    assert_receive {:parsed_two, _, _}
  end

  test "invalid target values cannot crash command and mention normalization" do
    body = "/deploy all complete arguments"

    for target <- [%{}, self(), {:private, "value"}, fn -> :private end, <<255>>] do
      result = Normalizer.normalize(context(body, nil), %{}, mention_targets: [target])
      assert result.body == body
      assert result.command.name == "deploy"
      assert result.command.argv == ["all", "complete", "arguments"]
      refute result.was_mentioned
      assert result.agent_mentions == []
    end
  end

  test "malformed retained mention structs cannot supply identity or strip command text" do
    for mention <- [
          struct!(Jido.Chat.Mention, %{user_id: self(), metadata: %{}}),
          struct!(Jido.Chat.Mention, %{username: %{}, metadata: %{offset: 0, length: 4}}),
          struct!(Jido.Chat.Mention, %{username: "bot", metadata: nil}),
          struct!(Jido.Chat.Mention, %{username: "bot", mention_text: <<255>>, metadata: %{}})
        ] do
      body = "/deploy complete"
      base = context(body, nil, %{mentions: [mention]})
      result = Normalizer.normalize(base, %{})
      assert result.body == body
      assert result.command.name == "deploy"
      assert result.command.source == :body
      refute result.was_mentioned
      assert result.mentions == []
    end
  end

  test "invalid mention spans preserve Unicode body and its complete command arguments" do
    for metadata <- [%{offset: 0, length: -1}, %{offset: "0", length: 4}, %{offset: 0, length: 100}] do
      base = context("/deploy é complete", nil, %{mentions: [%{username: "other", metadata: metadata}]})
      result = Normalizer.normalize(base, %{})
      assert result.body == "/deploy é complete"
      assert result.command.argv == ["é", "complete"]
      assert result.command.source == :body
      refute result.was_mentioned
    end
  end

  test "valid retained mention and supported target IDs preserve their full data" do
    mention =
      Jido.Chat.Mention.new(%{
        user_id: "42",
        username: "Bot",
        display_name: "Complete Bot Name",
        mention_text: "@bot",
        is_self: true,
        metadata: %{offset: 0, length: 4, private_display: "complete"}
      })

    base = context("@bot /deploy complete", nil, %{mentions: [mention]})
    result = Normalizer.normalize(base, %{}, mention_targets: [42, :bot])
    assert result.mentions == [mention]
    assert result.was_mentioned
    assert result.command.name == "deploy"
    assert result.command.argv == ["complete"]
    assert result.command.source == :mention_stripped
    assert result.body == base.body
    assert base.mentions == [mention]
  end
end
