defmodule Jido.Messaging.MixProject do
  use Mix.Project

  @version "1.1.1"
  @source_url "https://github.com/agentjido/jido_messaging"
  @description "Messaging and notification system for the Jido ecosystem"

  def project do
    [
      app: :jido_messaging,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_ignore_filters: [~r{(^test/support/|_helper\.exs$|^test/optional/jido_ai_integration\.exs$)}],

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
        summary: [threshold: 0],
        export: "cov"
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
        "test.core": :test,
        "test.integration": :test,
        "test.story": :test,
        "test.optional_jido_ai": :test,
        "test.all": :test,
        quality: :test,
        q: :test,
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
      {:jido_chat, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.14"},
      {:jido, "~> 2.3"},
      {:jido_signal, "~> 2.2"},
      {:jido_ai, "~> 2.2", optional: true},
      {:yaml_elixir, "~> 2.12"},
      {:plug, "~> 1.16"},
      {:exqlite, "~> 0.39.0"},

      # PubSub support (required by jido_signal, also used for integration tests)
      {:phoenix_pubsub, "~> 2.1"},

      # Environment loading
      {:dotenvy, "~> 1.1"},

      # Dev/Test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      test: "test --exclude flaky --exclude integration --exclude story",
      "test.core": "test --exclude flaky --exclude integration --exclude story",
      "test.integration": "test --only integration --exclude flaky",
      "test.story": "test --only story --exclude flaky",
      "test.optional_jido_ai": "run test/optional/jido_ai_integration.exs",
      "test.all": "test --exclude flaky --include integration --include story",
      q: ["quality"],
      cover: ["coveralls"],
      precommit: [
        "format --check-formatted",
        "cmd env MIX_ENV=test MIX_OS_CONCURRENCY_LOCK=0 mix compile --from-mix-deps-compile --warnings-as-errors",
        "cmd env ERL_LIBS=_build/test/lib elixir scripts/precommit_test_runner.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "examples/jido_ai",
        "docs",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "usage-rules.md"
      ],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_messaging/changelog.html",
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jido_messaging",
        "GitHub" => @source_url,
        "Website" => "https://jido.run"
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
        "CONTRIBUTING.md",
        "docs/agentic-identity.md",
        "docs/rfcs/0001-durable-delivery.md",
        "docs/message-correctness-hardening.md"
      ]
    ]
  end
end
