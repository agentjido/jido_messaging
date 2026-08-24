defmodule Mix.Tasks.JidoMessaging.Postgres.Migrate do
  @shortdoc "Installs Jido Messaging PostgreSQL migrations"

  @moduledoc """
  Installs all pending Jido Messaging PostgreSQL migrations.

      JIDO_MESSAGING_POSTGRES_URL=postgresql://... \
        mix jido_messaging.postgres.migrate

  Use `--url-env` to read the URL from a different environment variable. Do
  not put a database URL on the command line because process tools can show it.

      mix jido_messaging.postgres.migrate --url-env MY_DATABASE_URL
  """

  use Mix.Task

  alias Jido.Messaging.Persistence.Postgres

  @impl Mix.Task
  def run(args) do
    {opts, remaining, invalid} =
      OptionParser.parse(args, strict: [url_env: :string], aliases: [e: :url_env])

    if remaining != [] or invalid != [] do
      Mix.raise("invalid options; use --url-env ENVIRONMENT_VARIABLE")
    end

    Mix.Task.run("app.start")

    env_name = Keyword.get(opts, :url_env, "JIDO_MESSAGING_POSTGRES_URL")
    url = System.get_env(env_name) || Mix.raise("environment variable #{env_name} is not set")

    case Postgres.migrate(url: url, pool_size: 1) do
      :ok -> Mix.shell().info("Jido Messaging PostgreSQL migrations are current")
      {:error, reason} -> Mix.raise("Jido Messaging PostgreSQL migration failed: #{safe_reason(reason)}")
    end
  end

  defp safe_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "database error"
end
