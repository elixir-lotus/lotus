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
      Mimic.copy(Lotus.Config)

      config = [
        allow: [],
        deny: [
          "products",
          "order_items"
        ]
      ]

      Lotus.Config |> stub(:rules_for_source_name, fn _repo_name -> config end)
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
end
