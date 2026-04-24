defmodule Lotus.PreflightMysqlTest do
  use Lotus.Case
  use Mimic
  alias Lotus.Preflight
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  @moduletag :mysql

  @mysql_adapter EctoAdapter.wrap("mysql", Lotus.Test.MysqlRepo)

  describe "MySQL preflight authorization" do
    test "allows queries against regular tables" do
      assert :ok = Preflight.authorize(@mysql_adapter, Statement.new("SELECT 1", []))

      assert :ok =
               Preflight.authorize(
                 @mysql_adapter,
                 Statement.new("SELECT * FROM test_users LIMIT 1", [])
               )
    end

    test "allows complex queries with JOINs" do
      sql = """
        SELECT tp.title, tu.name, p.name
        FROM test_posts tp
        JOIN test_users tu ON tp.user_id = tu.id
        JOIN products p ON 1=1
        WHERE tu.active = 1
        LIMIT 10
      """

      assert :ok = Preflight.authorize(@mysql_adapter, Statement.new(sql, []))
    end

    test "allows simple queries" do
      assert :ok =
               Preflight.authorize(
                 @mysql_adapter,
                 Statement.new("SELECT * FROM test_posts WHERE user_id IS NOT NULL", [])
               )

      assert :ok =
               Preflight.authorize(
                 @mysql_adapter,
                 Statement.new("SELECT COUNT(*) FROM test_users", [])
               )
    end

    test "allows subqueries and CTEs" do
      # Subquery
      sql = """
        SELECT * FROM test_posts
        WHERE user_id IN (SELECT id FROM test_users WHERE active = 1)
      """

      assert :ok = Preflight.authorize(@mysql_adapter, Statement.new(sql, []))

      # CTE
      sql = """
        WITH user_stats AS (
          SELECT tu.id, tu.email, COUNT(tp.id) as post_count
          FROM test_users tu
          LEFT JOIN test_posts tp ON tu.id = tp.user_id
          GROUP BY tu.id, tu.email
        )
        SELECT * FROM user_stats WHERE post_count > 0
      """

      assert :ok = Preflight.authorize(@mysql_adapter, Statement.new(sql, []))
    end

    test "handles parameterized queries" do
      assert :ok =
               Preflight.authorize(
                 @mysql_adapter,
                 Statement.new("SELECT * FROM test_users WHERE id = ?", [1])
               )

      assert :ok =
               Preflight.authorize(
                 @mysql_adapter,
                 Statement.new("SELECT * FROM test_posts WHERE user_id = ?", [1])
               )
    end

    test "handles syntax errors gracefully" do
      {:error, _msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("INVALID SQL SYNTAX", []))
    end
  end

  describe "MySQL builtin deny tests" do
    test "blocks queries against information_schema" do
      {:error, msg} =
        Preflight.authorize(
          @mysql_adapter,
          Statement.new("SELECT * FROM information_schema.tables", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "information_schema"
    end

    test "blocks queries against information_schema columns" do
      {:error, msg} =
        Preflight.authorize(
          @mysql_adapter,
          Statement.new("SELECT * FROM information_schema.columns", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "information_schema"
    end

    test "blocks queries against mysql schema" do
      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM mysql.user", []))

      assert msg =~ "blocked table"
      assert msg =~ "mysql"
    end

    test "blocks queries against mysql db table" do
      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM mysql.db", []))

      assert msg =~ "blocked table"
      assert msg =~ "mysql"
    end

    test "blocks queries against performance_schema" do
      {:error, msg} =
        Preflight.authorize(
          @mysql_adapter,
          Statement.new("SELECT * FROM performance_schema.events_waits_current", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "performance_schema"
    end

    test "blocks queries against performance_schema tables" do
      {:error, msg} =
        Preflight.authorize(
          @mysql_adapter,
          Statement.new("SELECT * FROM performance_schema.threads", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "performance_schema"
    end

    test "blocks queries against sys schema" do
      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM sys.version", []))

      assert msg =~ "blocked table"
      assert msg =~ "sys"
    end

    test "blocks queries against sys schema tables" do
      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM sys.host_summary", []))

      assert msg =~ "blocked table"
      assert msg =~ "sys"
    end

    test "blocks queries against schema_migrations" do
      {:error, msg} =
        Preflight.authorize(
          @mysql_adapter,
          Statement.new("SELECT * FROM lotus_mysql_schema_migrations", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "schema_migrations"
    end

    test "blocks queries against lotus_queries" do
      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM lotus_queries", []))

      assert msg =~ "blocked table"
      assert msg =~ "lotus_queries"
    end

    test "blocks JOINs that include denied tables" do
      sql = """
        SELECT tu.name, sm.version
        FROM test_users tu
        JOIN lotus_mysql_schema_migrations sm ON 1=1
      """

      {:error, msg} = Preflight.authorize(@mysql_adapter, Statement.new(sql, []))
      assert msg =~ "blocked table"
      assert msg =~ "schema_migrations"
    end
  end

  describe "MySQL preflight with bare string deny rules" do
    setup do
      Mimic.copy(Lotus.Config)
      config = [allow: [], deny: ["test_users", "test_posts"]]
      Lotus.Config |> stub(:rules_for_source_name, fn _repo_name -> config end)
      :ok
    end

    test "blocks queries against tables matching bare string deny rules" do
      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM test_users", []))

      assert msg =~ "blocked table"
      assert msg =~ "test_users"

      {:error, msg} =
        Preflight.authorize(@mysql_adapter, Statement.new("SELECT * FROM test_posts", []))

      assert msg =~ "blocked table"
      assert msg =~ "test_posts"
    end

    test "blocks JOIN queries including denied tables" do
      sql = """
        SELECT tu.name, tp.title
        FROM test_users tu
        JOIN test_posts tp ON tu.id = tp.user_id
      """

      {:error, msg} = Preflight.authorize(@mysql_adapter, Statement.new(sql, []))
      assert msg =~ "blocked table"
      assert msg =~ "test_users"
      assert msg =~ "test_posts"
    end

    test "allows queries against tables not in deny list" do
      # products table is not in the deny list
      assert :ok =
               Preflight.authorize(
                 @mysql_adapter,
                 Statement.new("SELECT * FROM products LIMIT 1", [])
               )
    end
  end
end
