defmodule JidoMessaging.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/epic-creative/jido_messaging"
  @description "Messaging and notification system for the Jido ecosystem"

  def project do
    [
      app: :jido_messaging,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Documentation
      name: "Jido Messaging",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Test Coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime dependencies
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.14"},
      {:jido, github: "agentjido/jido", override: true},
      {:jido_signal, github: "agentjido/jido_signal", override: true},
      {:jido_ai, github: "agentjido/jido_ai"},

      # Telegram integration
      {:telegex, "~> 1.8"},
      {:finch, "~> 0.18"},
      {:multipart, "~> 0.4", override: true},

      # Discord integration (runtime: false to prevent auto-start in tests)
      {:nostrum, "~> 0.10", runtime: false},

      # Slack integration
      {:slack_elixir, "~> 1.2"},

      # WhatsApp integration
      {:whatsapp_elixir, "~> 0.1.8"},

      # PubSub support (required by jido_signal, also used for integration tests)
      {:phoenix_pubsub, "~> 2.1"},

      # Environment loading
      {:dotenvy, "~> 1.1"},

      # Dev/Test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      test: "test --exclude flaky",
      q: ["quality"],
      precommit: [
        "format --check-formatted",
        "cmd env MIX_ENV=test MIX_OS_CONCURRENCY_LOCK=0 mix compile --from-mix-deps-compile --warnings-as-errors",
        "cmd env ERL_LIBS=_build/test/lib elixir scripts/precommit_test_runner.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", "usage-rules.md"],
      maintainers: ["Epic Creative"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_messaging/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/jido_messaging",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md"
      ]
    ]
  end
end
