defmodule Lotus.PreflightPostgresTest do
  use Lotus.Case
  use Mimic
  alias Lotus.Preflight
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  @pg_adapter EctoAdapter.wrap("postgres", Lotus.Test.Repo)

  describe "PostgreSQL preflight authorization" do
    test "allows queries against regular tables" do
      assert :ok = Preflight.authorize(@pg_adapter, Statement.new("SELECT 1", []))

      assert :ok =
               Preflight.authorize(
                 @pg_adapter,
                 Statement.new("SELECT * FROM test_users LIMIT 1", [])
               )
    end

    test "allows complex queries with JOINs" do
      sql = """
        SELECT u.name, p.title, p.content
        FROM test_users u
        JOIN test_posts p ON u.id = p.user_id
        WHERE u.active = true
        LIMIT 10
      """

      assert :ok = Preflight.authorize(@pg_adapter, Statement.new(sql, []))
    end

    test "allows simple queries" do
      assert :ok =
               Preflight.authorize(
                 @pg_adapter,
                 Statement.new("SELECT * FROM test_posts WHERE published = true", [])
               )

      assert :ok =
               Preflight.authorize(
                 @pg_adapter,
                 Statement.new("SELECT COUNT(*) FROM test_users", [])
               )
    end

    test "allows subqueries and CTEs" do
      # Subquery
      sql = """
        SELECT * FROM test_users
        WHERE id IN (SELECT user_id FROM test_posts WHERE published = true)
      """

      assert :ok = Preflight.authorize(@pg_adapter, Statement.new(sql, []))

      # CTE
      sql = """
        WITH user_stats AS (
          SELECT u.id, u.name, COUNT(p.id) as post_count
          FROM test_users u
          LEFT JOIN test_posts p ON u.id = p.user_id
          GROUP BY u.id, u.name
        )
        SELECT * FROM user_stats WHERE post_count > 0
      """

      assert :ok = Preflight.authorize(@pg_adapter, Statement.new(sql, []))
    end

    test "handles parameterized queries" do
      assert :ok =
               Preflight.authorize(
                 @pg_adapter,
                 Statement.new("SELECT * FROM test_users WHERE id = $1", [1])
               )

      assert :ok =
               Preflight.authorize(
                 @pg_adapter,
                 Statement.new("SELECT * FROM test_posts WHERE view_count > $1", [10])
               )
    end

    test "handles syntax errors gracefully" do
      {:error, _msg} = Preflight.authorize(@pg_adapter, Statement.new("INVALID SQL SYNTAX", []))
    end
  end

  describe "PostgreSQL builtin deny tests" do
    test "blocks queries against pg_catalog schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM pg_catalog.pg_tables", []))

      assert msg =~ "blocked table"
      assert msg =~ "pg_catalog"
    end

    test "blocks queries against information_schema" do
      {:error, msg} =
        Preflight.authorize(
          @pg_adapter,
          Statement.new("SELECT * FROM information_schema.tables", [])
        )

      assert msg =~ "blocked table"
      # information_schema queries actually touch pg_catalog tables internally
      assert msg =~ "pg_catalog"
    end

    test "blocks queries against schema_migrations in public schema" do
      {:error, msg} =
        Preflight.authorize(
          @pg_adapter,
          Statement.new("SELECT * FROM public.schema_migrations", [])
        )

      assert msg =~ "blocked table"
      assert msg =~ "schema_migrations"
    end

    test "blocks queries against schema_migrations without schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM schema_migrations", []))

      assert msg =~ "blocked table"
      assert msg =~ "schema_migrations"
    end

    test "blocks queries against lotus_queries in public schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM public.lotus_queries", []))

      assert msg =~ "blocked table"
      assert msg =~ "lotus_queries"
    end

    test "blocks queries against lotus_queries without schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM lotus_queries", []))

      assert msg =~ "blocked table"
      assert msg =~ "lotus_queries"
    end

    test "blocks JOINs that include denied tables" do
      sql = """
        SELECT u.name, lq.name
        FROM test_users u
        JOIN lotus_queries lq ON true
      """

      {:error, msg} = Preflight.authorize(@pg_adapter, Statement.new(sql, []))
      assert msg =~ "blocked table"
      assert msg =~ "lotus_queries"
    end
  end

  describe "PostgreSQL preflight with bare string deny rules" do
    setup do
      Mimic.copy(Lotus.Config)

      config = [
        allow: [],
        deny: [
          "test_posts",
          "test_comments"
        ]
      ]

      Lotus.Config |> stub(:rules_for_source_name, fn _repo_name -> config end)
      :ok
    end

    test "blocks queries against tables matching bare string deny rules in public schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM test_posts", []))

      assert msg =~ "blocked table"
      assert msg =~ "test_posts"
    end

    test "blocks queries against tables matching bare string deny rules with explicit schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM public.test_posts", []))

      assert msg =~ "blocked table"
      assert msg =~ "test_posts"
    end

    test "blocks JOIN queries including denied tables" do
      sql = """
        SELECT u.name, p.title
        FROM test_users u
        JOIN test_posts p ON u.id = p.user_id
      """

      {:error, msg} = Preflight.authorize(@pg_adapter, Statement.new(sql, []))
      assert msg =~ "blocked table"
      assert msg =~ "test_posts"
    end

    test "allows queries against tables not in deny list" do
      assert :ok = Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM test_users", []))
      assert :ok = Preflight.authorize(@pg_adapter, Statement.new("SELECT 1", []))
    end
  end

  describe "PostgreSQL preflight with bare string allow rules" do
    setup do
      Mimic.copy(Lotus.Config)

      config = [
        allow: [
          "test_users"
        ],
        deny: []
      ]

      Lotus.Config |> stub(:rules_for_source_name, fn _repo_name -> config end)
      :ok
    end

    test "allows queries against tables matching bare string allow rules" do
      assert :ok = Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM test_users", []))
    end

    test "allows queries with explicit schema for allowed tables" do
      assert :ok =
               Preflight.authorize(
                 @pg_adapter,
                 Statement.new("SELECT * FROM public.test_users", [])
               )
    end

    test "blocks queries against tables not in allow list" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM test_posts", []))

      assert msg =~ "blocked table"
      assert msg =~ "test_posts"
    end
  end

  describe "PostgreSQL preflight with mixed rule formats" do
    setup do
      Mimic.copy(Lotus.Config)

      config = [
        allow: [],
        deny: [
          "test_comments",
          {"public", "test_posts"}
        ]
      ]

      Lotus.Config |> stub(:rules_for_source_name, fn _repo_name -> config end)
      :ok
    end

    test "tuple with schema only blocks in that specific schema" do
      {:error, msg} =
        Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM public.test_posts", []))

      assert msg =~ "blocked table"
      assert msg =~ "test_posts"
    end

    test "allows tables not matching any deny rules" do
      assert :ok = Preflight.authorize(@pg_adapter, Statement.new("SELECT * FROM test_users", []))
    end
  end
end
