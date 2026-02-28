defmodule Jido.Messaging.DecouplingTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)
  @mix_exs Path.join(@project_root, "mix.exs")

  test "mix deps do not include direct platform adapter packages" do
    source = File.read!(@mix_exs)

    refute source =~ "{:jido_chat_telegram"
    refute source =~ "{:jido_chat_discord"
  end

  test "runtime library has no direct Telegram/Discord adapter module references" do
    runtime_sources =
      @project_root
      |> Path.join("lib/jido_messaging/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute Regex.match?(~r/\bJido\.Chat\.(Telegram|Discord)\./, runtime_sources)
  end
end
