defmodule Lotus.Migrations.Postgres.V5 do
  @moduledoc """
  Add `query_language` to `lotus_queries`.

  The column records the language identifier (`family:dialect`, e.g.
  `sql:postgres`) that a stored query was written for. It is nullable:
  `NULL` means "derive the language from the data source's adapter", which
  is the behaviour of every row that existed before this migration.

  There is no backfill. A backfill would have to read runtime configuration
  and resolve adapters from inside a schema migration, and `NULL` already
  means exactly what a backfill would compute.
  """

  use Ecto.Migration

  def up(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    alter table(:lotus_queries, table_opts) do
      add(:query_language, :string, size: 32)
    end
  end

  def down(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    alter table(:lotus_queries, table_opts) do
      remove(:query_language)
    end
  end
end
