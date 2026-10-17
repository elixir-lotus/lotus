defmodule Lotus.SchemaRelationsTest do
  # Foreign keys, column comments, primary keys and row count estimates,
  # as describe_table/3 and table_row_estimates/2 report them.
  use Lotus.Case
  use Mimic

  alias Lotus.Schema
  alias Lotus.Test.{Repo, SqliteRepo}

  defp column(columns, name), do: Enum.find(columns, &(&1.name == name))

  describe "PostgreSQL" do
    test "a foreign key column names the column it references" do
      {:ok, columns} = Schema.describe_table("postgres", "test_posts", cache: :bypass)

      assert column(columns, "user_id").references ==
               %{schema: "public", table: "test_users", column: "id"}

      assert column(columns, "title").references == nil
      assert column(columns, "id").primary_key and not column(columns, "id").nullable
    end

    test "a foreign key across schemas keeps the referenced schema" do
      {:ok, columns} =
        Schema.describe_table("postgres", "orders", schema: "reporting", cache: :bypass)

      assert %{schema: "reporting", table: "customers", column: "id"} =
               column(columns, "customer_id").references
    end

    test "a column comment is the column's comment" do
      Repo.query!("COMMENT ON COLUMN test_users.email IS 'Login address, unique'")

      {:ok, columns} = Schema.describe_table("postgres", "test_users", cache: :bypass)

      assert column(columns, "email").comment == "Login address, unique"
      assert column(columns, "name").comment == nil
    end

    test "a reference to a relation the caller may not see is left out" do
      stub(Lotus.Visibility, :allowed_relation?, fn
        _source, {_schema, "test_users"}, _scope -> false
        _source, _relation, _scope -> true
      end)

      {:ok, columns} = Schema.describe_table("postgres", "test_posts", cache: :bypass)

      assert column(columns, "user_id").references == nil
    end

    test "row estimates come from the planner's statistics, for visible tables only" do
      Repo.query!("ANALYZE test_users")

      {:ok, estimates} = Schema.table_row_estimates("postgres", cache: :bypass)

      assert is_integer(estimates[{"public", "test_users"}])
      refute Map.has_key?(estimates, {"public", "lotus_queries"})
      refute Map.has_key?(estimates, {"public", "schema_migrations"})
    end

    test "a schema the caller may not see is refused" do
      assert {:error, "Schema(s) not visible: pg_catalog"} =
               Schema.table_row_estimates("postgres", schema: "pg_catalog")
    end
  end

  describe "SQLite" do
    @describetag :sqlite

    test "foreign keys, and every column of a primary key" do
      {:ok, columns} = Schema.describe_table("sqlite", "order_items", cache: :bypass)

      assert %{table: "orders", schema: nil} = column(columns, "order_id").references
      assert %{table: "products", schema: nil} = column(columns, "product_id").references

      SqliteRepo.query!("CREATE TABLE pairs (a INTEGER, b INTEGER, PRIMARY KEY (a, b))")
      {:ok, pairs} = Schema.describe_table("sqlite", "pairs", cache: :bypass)

      assert Enum.all?(pairs, &(&1.primary_key and not &1.nullable))
    end

    test "row estimates come from sqlite_stat1, after ANALYZE" do
      assert {:ok, %{}} = Schema.table_row_estimates("sqlite", cache: :bypass)

      SqliteRepo.query!("ANALYZE")
      {:ok, estimates} = Schema.table_row_estimates("sqlite", cache: :bypass)

      assert Enum.all?(estimates, fn {{nil, table}, rows} -> is_binary(table) and rows >= 0 end)
    end
  end

  describe "MySQL" do
    @describetag :mysql

    test "foreign keys and row estimates" do
      {:ok, columns} = Schema.describe_table("mysql", "test_posts", cache: :bypass)

      assert %{table: "test_users", column: "id"} = column(columns, "user_id").references

      # No ANALYZE TABLE: it commits, ending the test's sandbox transaction.
      {:ok, estimates} = Schema.table_row_estimates("mysql", cache: :bypass)

      assert Enum.any?(estimates, fn {{_db, table}, rows} ->
               table == "test_users" and is_integer(rows)
             end)
    end
  end
end
