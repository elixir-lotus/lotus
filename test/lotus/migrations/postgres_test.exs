defmodule Lotus.Migrations.PostgresTest do
  use Lotus.Case, async: true

  defmodule MigrationRepo do
    @moduledoc false

    use Ecto.Repo, otp_app: :lotus, adapter: Ecto.Adapters.Postgres

    alias Lotus.Test.Repo

    def init(_, _) do
      {:ok, Keyword.put(Repo.config(), :database, "lotus_migration_test")}
    end
  end

  test "migrating a postgres database" do
    MigrationRepo.__adapter__().storage_down(MigrationRepo.config())
    MigrationRepo.__adapter__().storage_up(MigrationRepo.config())

    start_supervised!(MigrationRepo)

    assert Ecto.Migrator.up(MigrationRepo, 1, Lotus.Migrations) in [:ok, :already_up]
    assert table_exists?("lotus_queries")
    assert column_exists?("lotus_queries", "query_language")

    assert :ok = Ecto.Migrator.down(MigrationRepo, 1, Lotus.Migrations)
    refute table_exists?("lotus_queries")
  after
    clear_migrated()
    MigrationRepo.__adapter__().storage_down(MigrationRepo.config())
  end

  defp table_exists?(table_name) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_name = $1
    )
    """

    {:ok, %{rows: [[exists]]}} = MigrationRepo.query(query, [table_name])

    exists
  end

  defp column_exists?(table_name, column_name) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_schema = 'public'
      AND table_name = $1
      AND column_name = $2
    )
    """

    {:ok, %{rows: [[exists]]}} = MigrationRepo.query(query, [table_name, column_name])

    exists
  end

  defp clear_migrated do
    MigrationRepo.query("DELETE FROM schema_migrations WHERE version >= '1'", [])
  end
end
