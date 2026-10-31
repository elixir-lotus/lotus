defmodule Lotus.PreflightSqliteTest do
  use Lotus.Case
  use Mimic
  alias Lotus.Preflight
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  @moduletag :sqlite

  @sqlite_adapter EctoAdapter.wrap("sqlite", Lotus.Test.SqliteRepo)

  describe "SQLite preflight authorization" do
    test "allows queries against regular tables" do
      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new("SELECT 1", []))

      assert :ok =
               Preflight.authorize(
                 @sqlite_adapter,
                 Statement.new("SELECT * FROM products LIMIT 1", [])
               )
    end

    test "allows complex queries with JOINs" do
      sql = """
        SELECT p.name, o.order_number, o.total_amount
        FROM products p
        JOIN order_items oi ON p.id = oi.product_id
        JOIN orders o ON oi.order_id = o.id
        WHERE p.active = 1
        LIMIT 10
      """

      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new(sql, []))
    end

    test "allows simple queries" do
      assert :ok =
               Preflight.authorize(
                 @sqlite_adapter,
                 Statement.new("SELECT * FROM orders WHERE status = 'pending'", [])
               )

      assert :ok =
               Preflight.authorize(
                 @sqlite_adapter,
                 Statement.new("SELECT COUNT(*) FROM products", [])
               )
    end

    test "allows subqueries and CTEs" do
      # Subquery
      sql = """
        SELECT * FROM products
        WHERE id IN (SELECT product_id FROM order_items WHERE quantity > 1)
      """

      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new(sql, []))

      # CTE
      sql = """
        WITH product_stats AS (
          SELECT p.id, p.name, COUNT(oi.id) as order_count
          FROM products p
          LEFT JOIN order_items oi ON p.id = oi.product_id
          GROUP BY p.id, p.name
        )
        SELECT * FROM product_stats WHERE order_count > 0
      """

      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new(sql, []))
    end

    test "handles parameterized queries" do
      assert :ok =
               Preflight.authorize(
                 @sqlite_adapter,
                 Statement.new("SELECT * FROM products WHERE id = ?", [1])
               )

      assert :ok =
               Preflight.authorize(
                 @sqlite_adapter,
                 Statement.new("SELECT * FROM orders WHERE total_amount > ?", [10.0])
               )
    end

    test "handles syntax errors gracefully" do
      {:error, _msg} =
        Preflight.authorize(@sqlite_adapter, Statement.new("INVALID SQL SYNTAX", []))
    end
  end

  describe "SQLite builtin deny tests" do
    test "blocks queries against schema_migrations" do
      {:error, msg} =
        Preflight.authorize(
          @sqlite_adapter,
          Statement.new("SELECT * FROM lotus_sqlite_schema_migrations", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "schema_migrations"
    end

    test "blocks queries against lotus_queries" do
      {:error, msg} =
        Preflight.authorize(@sqlite_adapter, Statement.new("SELECT * FROM lotus_queries", []))

      assert msg =~ "blocked table"
      assert msg =~ "lotus_queries"
    end

    test "blocks JOINs that include denied tables" do
      sql = """
        SELECT p.name, sm.version
        FROM products p
        JOIN lotus_sqlite_schema_migrations sm ON 1=1
      """

      {:error, msg} = Preflight.authorize(@sqlite_adapter, Statement.new(sql, []))
      assert msg =~ "blocked table"
      assert msg =~ "schema_migrations"
    end
  end

  describe "SQLite preflight with bare string deny rules" do
    setup do
      config = [
        allow: [],
        deny: [
          "products",
          "order_items"
        ]
      ]

      Lotus.Config |> stub(:visibility_for_source_name, fn _repo_name -> %{table: config} end)
      :ok
    end

    test "blocks queries against tables matching bare string deny rules" do
      {:error, msg} =
        Preflight.authorize(@sqlite_adapter, Statement.new("SELECT * FROM products", []))

      assert msg =~ "blocked table"
      assert msg =~ "products"

      {:error, msg} =
        Preflight.authorize(@sqlite_adapter, Statement.new("SELECT * FROM order_items", []))

      assert msg =~ "blocked table"
      assert msg =~ "order_items"
    end

    test "blocks JOIN queries including denied tables" do
      sql = """
        SELECT o.order_number, p.name
        FROM orders o
        JOIN order_items oi ON o.id = oi.order_id
        JOIN products p ON oi.product_id = p.id
      """

      {:error, msg} = Preflight.authorize(@sqlite_adapter, Statement.new(sql, []))
      assert msg =~ "blocked table"
      assert msg =~ "products"
      assert msg =~ "order_items"
    end

    test "allows queries against tables not in deny list" do
      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new("SELECT * FROM orders", []))
    end
  end

  describe "SQLite preflight reads the tables a statement opens" do
    setup do
      Lotus.Config
      |> stub(:visibility_for_source_name, fn _repo_name ->
        %{
          table: [deny: ["products"]],
          column: [{"orders", "total_amount", :omit}]
        }
      end)

      :ok
    end

    for sql <- [
          "SELECT p.name FROM orders, products p",
          "SELECT p.name FROM main.products p",
          "SELECT name FROM main.products",
          "SELECT * FROM (SELECT name FROM products a) s JOIN orders a ON 1 = 1",
          "SELECT * FROM PRODUCTS",
          ~s(SELECT name FROM "Products"),
          "SELECT sku FROM products INDEXED BY products_sku_index WHERE sku = 'x'"
        ] do
      test "blocks a denied table however the statement names it: #{sql}" do
        assert {:error, msg} =
                 Preflight.authorize(@sqlite_adapter, Statement.new(unquote(sql), []))

        assert msg =~ "blocked table"
        assert msg =~ "products"
      end
    end

    test "blocks the schema table in any case" do
      for sql <- ["SELECT name FROM SQLITE_MASTER", "SELECT name FROM Sqlite_Schema"] do
        assert {:error, msg} = Preflight.authorize(@sqlite_adapter, Statement.new(sql, []))
        assert msg =~ "sqlite_master", sql
      end
    end

    test "a column rule holds whatever case the table is named in" do
      assert {:ok, %{columns: ["order_number"]}} =
               Lotus.run_statement("SELECT order_number, total_amount FROM ORDERS", [],
                 repo: "sqlite"
               )
    end

    test "a table the statement doesn't open is not touched" do
      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new("SELECT * FROM orders", []))
    end
  end

  describe "SQLite discovery of a table named in another case" do
    setup do
      Lotus.Config
      |> stub(:visibility_for_source_name, fn _repo_name -> %{table: [deny: ["products"]]} end)

      :ok
    end

    test "describe_table and get_table_stats refuse a denied table in any case" do
      for name <- ["products", "PRODUCTS", "Products"] do
        assert {:error, _} = Lotus.Schema.describe_table("sqlite", name), name
        assert {:error, _} = Lotus.Schema.get_table_stats("sqlite", name), name
      end

      assert {:error, _} = Lotus.Schema.describe_table("sqlite", "SQLITE_MASTER")
    end

    test "a table named as stored is described" do
      assert {:ok, [_ | _]} = Lotus.Schema.describe_table("sqlite", "orders")
      assert {:ok, %{row_count: _}} = Lotus.Schema.get_table_stats("sqlite", "orders")
    end
  end

  describe "SQLite introspection statements" do
    setup do
      Lotus.Config
      |> stub(:visibility_for_source_name, fn _repo_name -> %{table: [deny: ["products"]]} end)

      :ok
    end

    for sql <- [
          "PRAGMA table_info(products)",
          "PRAGMA main.table_xinfo('Products')",
          "PRAGMA index_list([products])",
          "PRAGMA foreign_key_list(products)",
          "PRAGMA index_info(products_sku_index)",
          "EXPLAIN SELECT name FROM products",
          "EXPLAIN QUERY PLAN SELECT name FROM products",
          "/* x */ EXPLAIN SELECT name FROM products",
          "SELECT name, type FROM pragma_table_info('products')",
          "SELECT * FROM orders, pragma_index_info('products_sku_index')",
          ~s(SELECT * FROM "pragma_table_info"\('products'\))
        ] do
      test "are refused on a denied table: #{sql}" do
        assert {:error, msg} = Lotus.run_statement(unquote(sql), [], repo: "sqlite")
        assert msg =~ "blocked table"
        assert msg =~ "products"
      end
    end

    test "a pragma function whose table only the query tells is refused" do
      for sql <- [
            "SELECT p.name FROM sqlite_master m, pragma_table_info(m.name) p",
            "SELECT * FROM pragma_table_info('pro' || 'ducts')",
            "SELECT * FROM pragma_table_info((SELECT 'products'))"
          ] do
        assert {:error, _} = Lotus.run_statement(sql, [], repo: "sqlite"), sql
      end
    end

    test "run on a visible table" do
      for sql <- [
            "PRAGMA table_info(orders)",
            "PRAGMA foreign_keys",
            "EXPLAIN QUERY PLAN SELECT * FROM orders",
            "SELECT name FROM pragma_table_info('orders')"
          ] do
        assert {:ok, %{rows: [_ | _]}} = Lotus.run_statement(sql, [], repo: "sqlite"), sql
      end
    end
  end
end
