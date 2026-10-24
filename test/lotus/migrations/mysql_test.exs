defmodule Lotus.Migrations.MySQLTest do
  use Lotus.Case, async: true

  defmodule MigrationRepo do
    @moduledoc false

    use Ecto.Repo, otp_app: :lotus, adapter: Ecto.Adapters.MyXQL

    alias Lotus.Test.MysqlRepo

    def init(_, _) do
      {:ok, Keyword.put(MysqlRepo.config(), :database, "lotus_migration_test")}
    end
  end

  @moduletag :mysql

  defmodule Migration do
    use Ecto.Migration

    defdelegate up, to: Lotus.Migrations
    defdelegate down, to: Lotus.Migrations
  end

  test "migrating a mysql database" do
    MigrationRepo.__adapter__().storage_up(MigrationRepo.config())

    start_supervised!(MigrationRepo)

    assert Ecto.Migrator.up(MigrationRepo, 1, Lotus.Migrations) in [:ok, :already_up]
    assert table_exists?("lotus_queries")
    assert column_exists?("lotus_queries", "query_language")
    assert column_exists?("lotus_dashboard_filters", "source_query_id")
    assert column_exists?("lotus_dashboard_filters", "depends_on_filter_id")

    for table <- ~w(lotus_queries lotus_dashboards) do
      assert column_exists?(table, "owner_id")
      assert column_exists?(table, "tenant_id")
    end

    assert table_exists?("lotus_schedules")
    assert table_exists?("lotus_schedule_runs")
    assert column_exists?("lotus_schedules", "next_run_at")
    assert column_exists?("lotus_schedule_runs", "scheduled_for")

    # A name is unique within a tenant, and among the rows without one.
    assert {:ok, _} = insert_query("Revenue", "acme")
    assert {:ok, _} = insert_query("Revenue", "globex")
    assert {:ok, _} = insert_query("Revenue", nil)
    assert {:error, %{mysql: %{name: :ER_DUP_ENTRY}}} = insert_query("Revenue", "acme")
    assert {:error, %{mysql: %{name: :ER_DUP_ENTRY}}} = insert_query("Revenue", nil)

    assert :ok = Ecto.Migrator.down(MigrationRepo, 1, Lotus.Migrations)
    refute table_exists?("lotus_queries")
  after
    MigrationRepo.__adapter__().storage_down(MigrationRepo.config())
  end

  defp column_exists?(table_name, column_name) do
    query = """
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = 'lotus_migration_test'
      AND TABLE_NAME = '#{table_name}'
      AND COLUMN_NAME = '#{column_name}'
    )
    """

    {:ok, %{rows: [[exists]]}} = MigrationRepo.query(query)

    exists != 0
  end

  defp table_exists?(table_name) do
    query = """
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = 'lotus_migration_test'
      AND TABLE_NAME = '#{table_name}'
    )
    """

    {:ok, %{rows: [[exists]]}} = MigrationRepo.query(query)

    exists != 0
  end

  defp insert_query(name, tenant_id) do
    MigrationRepo.query(
      "INSERT INTO lotus_queries (name, statement, tenant_id) VALUES (?, 'SELECT 1', ?)",
      [name, tenant_id]
    )
  end
end
