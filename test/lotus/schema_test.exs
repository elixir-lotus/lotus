defmodule Lotus.SchemaTest do
  use Lotus.Case
  use Mimic

  alias Lotus.Schema

  describe "SQLite source" do
    @tag :sqlite
    test "lists schemas (returns empty for schema-less database)" do
      {:ok, schemas} = Schema.list_schemas(Lotus.Test.SqliteRepo)

      assert is_list(schemas)
      assert schemas == []
    end

    @tag :sqlite
    test "lists tables from a data repo by name" do
      {:ok, tables} = Schema.list_tables("sqlite")

      assert is_list(tables)
      assert "orders" in tables
      assert "order_items" in tables
      assert "products" in tables
    end

    @tag :sqlite
    test "lists tables from a repo module directly" do
      {:ok, tables} = Schema.list_tables(Lotus.Test.SqliteRepo)

      assert is_list(tables)
      assert "orders" in tables
      assert "order_items" in tables
      assert "products" in tables
    end

    @tag :sqlite
    test "filters out system tables" do
      {:ok, tables} = Schema.list_tables(Lotus.Test.SqliteRepo)

      refute Enum.any?(tables, &String.starts_with?(&1, "sqlite_"))
      refute Enum.any?(tables, &String.starts_with?(&1, "lotus_"))
    end

    @tag :sqlite
    test "gets schema for a table" do
      {:ok, schema} = Schema.describe_table("sqlite", "products")

      assert is_list(schema)
      refute Enum.empty?(schema)

      column_names = Enum.map(schema, & &1.name)
      assert "id" in column_names
      assert "name" in column_names
      assert "price" in column_names
      assert "stock_quantity" in column_names

      id_col = Enum.find(schema, &(&1.name == "id"))
      assert id_col.primary_key == true
      assert id_col.nullable == true

      name_col = Enum.find(schema, &(&1.name == "name"))
      assert name_col.type =~ "TEXT" or name_col.type =~ "VARCHAR"
      assert name_col.nullable == false

      price_col = Enum.find(schema, &(&1.name == "price"))
      assert price_col.type =~ "DECIMAL" or price_col.type =~ "NUMERIC"
    end

    @tag :sqlite
    test "gets schema for a table with foreign keys" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.SqliteRepo, "order_items")

      column_names = Enum.map(schema, & &1.name)
      assert "order_id" in column_names
      assert "product_id" in column_names
      assert "quantity" in column_names
      assert "unit_price" in column_names
    end

    @tag :sqlite
    test "returns empty schema for non-existent table" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.SqliteRepo, "non_existent_table")

      assert schema == []
    end

    @tag :sqlite
    test "includes default values in schema" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.SqliteRepo, "products")

      stock_quantity_col = Enum.find(schema, &(&1.name == "stock_quantity"))
      assert stock_quantity_col.default != nil
    end

    @tag :sqlite
    test "returns zero row count for empty table" do
      {:ok, stats} = Schema.get_table_stats(Lotus.Test.SqliteRepo, "products")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
      assert stats.row_count == 0
    end

    @tag :sqlite
    test "returns error for table stats on non-existent table" do
      {:error, error} = Schema.get_table_stats(Lotus.Test.SqliteRepo, "non_existent_table")

      assert error =~ "no such table" or error =~ "does not exist"
    end

    @tag :sqlite
    test "gets row count for a table with data" do
      insert_test_data(Lotus.Test.SqliteRepo)

      {:ok, stats} = Schema.get_table_stats("sqlite", "products")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
      assert stats.row_count >= 0
    end
  end

  describe "PostgreSQL source" do
    @tag :postgres
    test "lists schemas" do
      {:ok, schemas} = Schema.list_schemas(Lotus.Test.Repo)

      assert is_list(schemas)
      assert "public" in schemas
      assert "reporting" in schemas
    end

    @tag :postgres
    test "lists tables from a data repo by name" do
      {:ok, tables} = Schema.list_tables("postgres")

      assert is_list(tables)
      assert {"public", "test_users"} in tables
      assert {"public", "test_posts"} in tables
    end

    @tag :postgres
    test "lists tables from a repo module directly" do
      {:ok, tables} = Schema.list_tables(Lotus.Test.Repo)

      assert is_list(tables)
      assert {"public", "test_users"} in tables
      assert {"public", "test_posts"} in tables
    end

    @tag :postgres
    test "filters out system tables" do
      {:ok, tables} = Schema.list_tables(Lotus.Test.Repo)

      refute Enum.any?(tables, fn {schema, _table} ->
               schema in ["pg_catalog", "information_schema"]
             end)

      refute Enum.any?(tables, fn {_schema, table} ->
               table in ["schema_migrations", "lotus_queries"]
             end)
    end

    @tag :postgres
    test "gets schema for a table" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.Repo, "test_users")

      assert is_list(schema)
      refute Enum.empty?(schema)

      column_names = Enum.map(schema, & &1.name)
      assert "id" in column_names
      assert "name" in column_names

      id_col = Enum.find(schema, &(&1.name == "id"))
      assert id_col.type =~ "bigint" or id_col.type =~ "integer"
      assert id_col.primary_key == true

      name_col = Enum.find(schema, &(&1.name == "name"))
      assert name_col.type =~ "character varying" or name_col.type =~ "varchar"
    end

    @tag :postgres
    test "gets schema for a table with schema prefix" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.Repo, "test_users", schema: "public")

      assert is_list(schema)
      refute Enum.empty?(schema)

      column_names = Enum.map(schema, & &1.name)
      assert "id" in column_names
      assert "name" in column_names
    end

    @tag :postgres
    test "returns error for non-existent table" do
      {:error, error} = Schema.describe_table(Lotus.Test.Repo, "non_existent_table")

      assert error =~ "not found"
    end

    @tag :postgres
    test "returns zero row count for empty table" do
      {:ok, stats} = Schema.get_table_stats(Lotus.Test.Repo, "test_users")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
      assert stats.row_count >= 0
    end

    @tag :postgres
    test "returns error for table stats on non-existent table" do
      {:error, error} = Schema.get_table_stats(Lotus.Test.Repo, "non_existent_table")

      assert error =~ "does not exist" or error =~ "not found"
    end
  end

  describe "MySQL source" do
    @tag :mysql
    test "lists schemas" do
      {:ok, schemas} = Schema.list_schemas(Lotus.Test.MysqlRepo)

      assert is_list(schemas)
      assert "lotus_test" in schemas
    end

    @tag :mysql
    test "lists tables from a data repo by name" do
      {:ok, tables} = Schema.list_tables("mysql")

      assert is_list(tables)
      # Tables should be returned as {database, table} tuples
      assert Enum.any?(tables, fn
               {_schema, "products"} -> true
               _ -> false
             end)

      assert Enum.any?(tables, fn
               {_schema, "orders"} -> true
               _ -> false
             end)

      assert Enum.any?(tables, fn
               {_schema, "order_items"} -> true
               _ -> false
             end)
    end

    @tag :mysql
    test "lists tables from a repo module directly" do
      {:ok, tables} = Schema.list_tables(Lotus.Test.MysqlRepo)

      assert is_list(tables)

      assert Enum.any?(tables, fn
               {_schema, "products"} -> true
               _ -> false
             end)

      assert Enum.any?(tables, fn
               {_schema, "orders"} -> true
               _ -> false
             end)

      assert Enum.any?(tables, fn
               {_schema, "order_items"} -> true
               _ -> false
             end)
    end

    @tag :mysql
    test "filters out system tables" do
      {:ok, tables} = Schema.list_tables(Lotus.Test.MysqlRepo)

      refute Enum.any?(tables, fn {schema, _table} ->
               schema in ["information_schema", "mysql", "performance_schema", "sys"]
             end)

      refute Enum.any?(tables, fn {_schema, table} ->
               table in ["schema_migrations", "lotus_mysql_schema_migrations", "lotus_queries"]
             end)
    end

    @tag :mysql
    test "gets schema for a table" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.MysqlRepo, "products")

      assert is_list(schema)
      refute Enum.empty?(schema)

      column_names = Enum.map(schema, & &1.name)
      assert "id" in column_names
      assert "name" in column_names
      assert "price" in column_names
      assert "stock_quantity" in column_names

      id_col = Enum.find(schema, &(&1.name == "id"))
      assert id_col.primary_key == true

      name_col = Enum.find(schema, &(&1.name == "name"))
      assert name_col.type =~ "varchar"
      assert name_col.nullable == false

      price_col = Enum.find(schema, &(&1.name == "price"))
      assert price_col.type =~ "decimal"
    end

    @tag :mysql
    test "gets schema for a table with foreign keys" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.MysqlRepo, "order_items")

      column_names = Enum.map(schema, & &1.name)
      assert "order_id" in column_names
      assert "product_id" in column_names
      assert "quantity" in column_names
      assert "unit_price" in column_names
    end

    @tag :mysql
    test "returns error for non-existent table" do
      {:error, error} = Schema.describe_table(Lotus.Test.MysqlRepo, "non_existent_table")

      assert error =~ "not found"
    end

    @tag :mysql
    test "includes default values in schema" do
      {:ok, schema} = Schema.describe_table(Lotus.Test.MysqlRepo, "products")

      stock_quantity_col = Enum.find(schema, &(&1.name == "stock_quantity"))
      assert stock_quantity_col.default != nil
    end

    @tag :mysql
    test "returns zero row count for empty table" do
      {:ok, stats} = Schema.get_table_stats(Lotus.Test.MysqlRepo, "products")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
      assert stats.row_count >= 0
    end

    @tag :mysql
    test "returns error for table stats on non-existent table" do
      {:error, error} = Schema.get_table_stats(Lotus.Test.MysqlRepo, "non_existent_table")

      assert error =~ "doesn't exist" or error =~ "not found"
    end
  end

  describe "general error handling" do
    test "returns error for non-existent repo name" do
      assert_raise ArgumentError, ~r/Data source \"nonexistent\" not configured/, fn ->
        Schema.list_tables("nonexistent")
      end
    end

    test "list_schemas returns error for non-existent repo name" do
      assert_raise ArgumentError, ~r/Data source \"nonexistent\" not configured/, fn ->
        Schema.list_schemas("nonexistent")
      end
    end

    test "describe_table returns error for non-existent repo name" do
      assert_raise ArgumentError, ~r/Data source \"nonexistent\" not configured/, fn ->
        Schema.describe_table("nonexistent", "some_table")
      end
    end

    test "get_table_stats returns error for non-existent repo name" do
      assert_raise ArgumentError, ~r/Data source \"nonexistent\" not configured/, fn ->
        Schema.get_table_stats("nonexistent", "some_table")
      end
    end
  end

  describe "integration with Lotus module" do
    @tag :sqlite
    test "list_tables is accessible through main module for SQLite" do
      {:ok, tables} = Lotus.list_tables("sqlite")

      assert is_list(tables)
      refute Enum.empty?(tables)
    end

    @tag :postgres
    test "list_tables is accessible through main module for PostgreSQL" do
      {:ok, tables} = Lotus.list_tables("postgres")

      assert is_list(tables)
      refute Enum.empty?(tables)
    end

    @tag :mysql
    test "list_tables is accessible through main module for MySQL" do
      {:ok, tables} = Lotus.list_tables("mysql")

      assert is_list(tables)
      refute Enum.empty?(tables)
    end

    @tag :sqlite
    test "describe_table is accessible through main module for SQLite" do
      {:ok, schema} = Lotus.describe_table("sqlite", "products")

      assert is_list(schema)
      refute Enum.empty?(schema)
    end

    @tag :postgres
    test "describe_table is accessible through main module for PostgreSQL" do
      {:ok, schema} = Lotus.describe_table("postgres", "test_users")

      assert is_list(schema)
      refute Enum.empty?(schema)
    end

    @tag :mysql
    test "describe_table is accessible through main module for MySQL" do
      {:ok, schema} = Lotus.describe_table("mysql", "products")

      assert is_list(schema)
      refute Enum.empty?(schema)
    end

    @tag :sqlite
    test "get_table_stats is accessible through main module for SQLite" do
      {:ok, stats} = Lotus.get_table_stats("sqlite", "products")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
    end

    @tag :postgres
    test "get_table_stats is accessible through main module for PostgreSQL" do
      {:ok, stats} = Lotus.get_table_stats("postgres", "test_users")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
    end

    @tag :mysql
    test "get_table_stats is accessible through main module for MySQL" do
      {:ok, stats} = Lotus.get_table_stats("mysql", "products")

      assert is_map(stats)
      assert Map.has_key?(stats, :row_count)
    end

    @tag :sqlite
    test "list_schemas is accessible through main module for SQLite" do
      {:ok, schemas} = Lotus.list_schemas("sqlite")

      assert is_list(schemas)
      assert schemas == []
    end

    @tag :postgres
    test "list_schemas is accessible through main module for PostgreSQL" do
      {:ok, schemas} = Lotus.list_schemas("postgres")

      assert is_list(schemas)
      assert "public" in schemas
    end

    @tag :mysql
    test "list_schemas is accessible through main module for MySQL" do
      {:ok, schemas} = Lotus.list_schemas("mysql")

      assert is_list(schemas)
      refute Enum.empty?(schemas)
    end
  end

  defp insert_test_data(repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo.query!("""
      INSERT INTO products (name, sku, description, price, stock_quantity, inserted_at, updated_at)
      VALUES
        ('Test Product 1', 'SKU001', 'Description 1', 19.99, 100, '#{now}', '#{now}'),
        ('Test Product 2', 'SKU002', 'Description 2', 29.99, 50, '#{now}', '#{now}'),
        ('Test Product 3', 'SKU003', 'Description 3', 39.99, 25, '#{now}', '#{now}')
    """)
  end

  describe "adapter error propagation" do
    setup do
      Mimic.copy(Lotus.Source)
      Mimic.copy(Lotus.Source.Adapter)

      adapter = %Lotus.Source.Adapter{
        name: "postgres",
        module: Lotus.Source.Adapters.Ecto,
        state: Lotus.Test.Repo,
        source_type: :postgres
      }

      Lotus.Source
      |> stub(:resolve!, fn _repo, _fallback -> adapter end)

      Lotus.Source.Adapter
      |> stub(:default_schemas, fn _adapter -> ["public"] end)

      {:ok, adapter: adapter}
    end

    test "describe_table/3 propagates permission errors from resolve_table_namespace" do
      Lotus.Source.Adapter
      |> expect(:resolve_table_namespace, fn _adapter, _table, _schemas ->
        {:error, "permission denied for schema reporting"}
      end)

      assert {:error, "permission denied for schema reporting"} =
               Schema.describe_table("postgres", "orders", schema: "reporting")
    end

    test "get_table_stats/3 propagates connection errors from resolve_table_namespace" do
      Lotus.Source.Adapter
      |> expect(:resolve_table_namespace, fn _adapter, _table, _schemas ->
        {:error, "connection refused"}
      end)

      assert {:error, "connection refused"} =
               Schema.get_table_stats("postgres", "orders", schema: "reporting")
    end

    test "describe_table/3 propagates errors with schemas option" do
      Lotus.Source.Adapter
      |> expect(:resolve_table_namespace, fn _adapter, _table, _schemas ->
        {:error, "permission denied"}
      end)

      assert {:error, "permission denied"} =
               Schema.describe_table("postgres", "orders", schemas: ["reporting", "public"])
    end

    test "describe_table/3 propagates errors with search_path option" do
      Lotus.Source.Adapter
      |> expect(:resolve_table_namespace, fn _adapter, _table, _schemas ->
        {:error, "permission denied"}
      end)

      assert {:error, "permission denied"} =
               Schema.describe_table("postgres", "orders", search_path: "reporting, public")
    end

    test "adapter errors are not cached — retried on next call" do
      Lotus.Source.Adapter
      |> expect(:resolve_table_namespace, fn _adapter, _table, _schemas ->
        {:error, "transient error"}
      end)

      assert {:error, "transient error"} =
               Schema.describe_table("postgres", "orders", schema: "reporting")

      Lotus.Source.Adapter
      |> expect(:resolve_table_namespace, fn _adapter, _table, _schemas ->
        {:ok, "reporting"}
      end)

      Lotus.Source.Adapter
      |> expect(:describe_table, fn _adapter, _schema, _table ->
        {:ok, [%{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}]}
      end)

      assert {:ok, [%{name: "id"}]} =
               Schema.describe_table("postgres", "orders", schema: "reporting")
    end
  end
end
