defmodule Jido.Messaging.Persistence.Postgres.Migrations do
  @moduledoc false

  @migration_path Path.expand("../../../../priv/postgres_migrations/001_create_records.sql", __DIR__)
  @external_resource @migration_path

  @statements @migration_path
              |> File.read!()
              |> String.split("-- jido-messaging-statement", trim: true)
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

  @migrations [{1, "create_records", @statements}]

  @doc "Returns ordered package migrations and their SQL statements."
  @spec all() :: [{pos_integer(), String.t(), [String.t()]}]
  def all, do: @migrations

  @doc "Returns the newest package migration version."
  @spec current_version() :: non_neg_integer()
  def current_version do
    @migrations
    |> List.last()
    |> elem(0)
  end
end
