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
      chat_dependency(),
      {:jason, "~> 1.4"},
      upstream_dependency(:zoi, "~> 0.18.11", "mikehostetler/zoi", "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9"),
      upstream_dependency(:jido, "~> 3.0.0-beta.1", "agentjido/jido", "90763478104f1edbf0afcfcf9444621c3f9755e8"),
      upstream_dependency(
        :jido_action,
        "~> 3.0.0-beta.12",
        "agentjido/jido_action",
        "8e9b3f7b268e175091b0eb3720bab3b8633d3c24"
      ),
      {:runic, "== 0.1.0-alpha.11"},
      upstream_dependency(
        :jido_signal,
        "~> 3.0.0-beta.4",
        "agentjido/jido_signal",
        "d6611eca1c95eb507843baceb55991e4801d8421"
      ),
      upstream_dependency(:jido_ai, "~> 3.0", "agentjido/jido_ai", "1f19ff262081bc13eb30da7bff8bfe42685d63c8",
        optional: true
      ),
      {:yaml_elixir, "~> 2.12"},
      {:plug, "~> 1.16"},
      {:exqlite, "~> 0.42.0"},
      {:postgrex, "~> 0.22.4"},

      # PubSub support (required by jido_signal, also used for integration tests)
      {:phoenix_pubsub, "~> 2.1"},

      # Environment loading
      {:dotenvy, "~> 1.1"},

      # Dev/Test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp upstream_dependency(app, requirement, repository, ref, opts \\ []) do
    if Mix.env() in [:dev, :test] or System.get_env("MIX_ENV") in ["dev", "test"] do
      {app, Keyword.merge([git: "https://github.com/" <> repository <> ".git", ref: ref, override: true], opts)}
    else
      {app, requirement, opts}
    end
  end

  # Local integration uses an explicit dev/test checkout. Production uses the package source.
  defp chat_dependency do
    case {Mix.env(), System.get_env("JIDO_CHAT_PATH")} do
      {env, path} when env in [:dev, :test] and is_binary(path) and path != "" ->
        {:jido_chat, path: Path.expand(path), override: true}

      {env, _} when env in [:dev, :test] ->
        {:jido_chat,
         git: "https://github.com/agentjido/jido_chat.git",
         ref: "2a9c21a860cb8c5f1069a865a981a8be035f56c0",
         override: true}

      _ ->
        {:jido_chat, "~> 2.0"}
    end
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
        "priv/postgres_migrations",
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
        "docs/jidoka-agent-discovery.md",
        "docs/jidoka-activity-projection.md",
        "docs/identity-credentials.md",
        "docs/principal-authorization.md",
        "docs/jidoka-agent-endpoints.md",
        "docs/agentic-identity.md",
        "docs/postgresql.md",
        "docs/rfcs/0001-durable-delivery.md",
        "docs/message-correctness-hardening.md",
        "docs/advisory-trust-evidence.md",
        "docs/jidoka-delegation-messaging.md",
        "docs/jidoka-continuity-boundary.md"
      ]
    ]
  end
end
