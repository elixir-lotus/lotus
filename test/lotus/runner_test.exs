defmodule Lotus.RunnerTest do
  use Lotus.Case, async: true
  use Mimic

  alias Lotus.Fixtures
  alias Lotus.Preflight.Relations
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.MysqlRepo
  alias Lotus.Test.Repo
  alias Lotus.Test.SqliteRepo

  @pg_adapter EctoAdapter.wrap("postgres", Repo)
  @sqlite_adapter EctoAdapter.wrap("sqlite", SqliteRepo)
  @mysql_adapter EctoAdapter.wrap("mysql", MysqlRepo)

  setup do
    fixtures = Fixtures.setup_test_data()
    {:ok, fixtures}
  end

  describe "run_statement/4 with real tables" do
    test "executes simple SELECT queries", %{users: %{kerouac: kerouac}} do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT name, email FROM test_users WHERE id = $1", [
            kerouac.id
          ])
        )

      assert {:ok, %{columns: ["name", "email"], rows: [["Jack Kerouac", "jack@ontheroad.com"]]}} =
               result
    end

    test "executes queries with multiple parameters", %{
      users: %{kerouac: kerouac, thompson: thompson}
    } do
      sql = "SELECT name, age FROM test_users WHERE id IN ($1, $2) ORDER BY name"
      result = Runner.run_statement(@pg_adapter, Statement.new(sql, [kerouac.id, thompson.id]))

      assert {:ok,
              %{
                columns: ["name", "age"],
                rows: [["Hunter S. Thompson", 37], ["Jack Kerouac", 47]]
              }} =
               result
    end

    test "executes JOIN queries", %{users: %{kerouac: kerouac}} do
      sql = """
      SELECT u.name, p.title, p.view_count
      FROM test_users u
      JOIN test_posts p ON u.id = p.user_id
      WHERE u.id = $1
      ORDER BY p.view_count DESC
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql, [kerouac.id]))

      assert {:ok,
              %{
                columns: ["name", "title", "view_count"],
                rows: [
                  ["Jack Kerouac", "The Mad Ones", 150],
                  ["Jack Kerouac", "First Thought Best Thought", 75]
                ]
              }} = result
    end

    test "executes aggregate queries" do
      sql = """
      SELECT
        COUNT(*) as total_posts,
        SUM(view_count) as total_views,
        AVG(view_count)::integer as avg_views
      FROM test_posts
      WHERE published = true
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok,
              %{
                columns: ["total_posts", "total_views", "avg_views"],
                rows: [[3, 425, 142]]
              }} = result
    end

    test "executes GROUP BY queries" do
      sql = """
      SELECT
        u.name,
        COUNT(p.id) as post_count,
        COALESCE(SUM(p.view_count), 0) as total_views
      FROM test_users u
      LEFT JOIN test_posts p ON u.id = p.user_id
      GROUP BY u.id, u.name
      ORDER BY u.name
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok,
              %{
                columns: ["name", "post_count", "total_views"],
                rows: [
                  ["Charles Bukowski", 1, 200],
                  ["Hunter S. Thompson", 1, 0],
                  ["Jack Kerouac", 2, 225]
                ]
              }} = result
    end

    test "handles JSON operations", %{users: %{kerouac: kerouac}} do
      sql = "SELECT name, metadata->>'role' as role FROM test_users WHERE id = $1"
      result = Runner.run_statement(@pg_adapter, Statement.new(sql, [kerouac.id]))
      assert {:ok, %{columns: ["name", "role"], rows: [["Jack Kerouac", "admin"]]}} = result
    end

    test "handles array operations" do
      sql =
        "SELECT title, array_length(tags, 1) as tag_count FROM test_posts WHERE 'beat' = ANY(tags)"

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:ok, %{columns: ["title", "tag_count"], rows: rows}} = result
      assert length(rows) == 2
    end

    test "executes CTE queries" do
      sql = """
      WITH active_users AS (
        SELECT id, name FROM test_users WHERE active = true
      ),
      user_posts AS (
        SELECT u.name, COUNT(p.id) as post_count
        FROM active_users u
        LEFT JOIN test_posts p ON u.id = p.user_id
        GROUP BY u.name
      )
      SELECT * FROM user_posts ORDER BY name
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok,
              %{
                columns: ["name", "post_count"],
                rows: [["Hunter S. Thompson", 1], ["Jack Kerouac", 2]]
              }} = result
    end

    test "handles subqueries" do
      sql = """
      SELECT name, email FROM test_users
      WHERE id IN (
        SELECT DISTINCT user_id FROM test_posts WHERE published = true
      )
      ORDER BY name
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["name", "email"], rows: rows}} = result
      assert length(rows) == 2
      assert Enum.any?(rows, fn [name, _] -> name == "Jack Kerouac" end)
      assert Enum.any?(rows, fn [name, _] -> name == "Charles Bukowski" end)
    end

    test "handles CASE expressions" do
      sql = """
      SELECT
        name,
        CASE
          WHEN age < 30 THEN 'Young'
          WHEN age >= 30 AND age < 50 THEN 'Middle'
          ELSE 'Senior'
        END as age_group
      FROM test_users
      ORDER BY name
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["name", "age_group"], rows: rows}} = result
      assert ["Charles Bukowski", "Senior"] in rows
      assert ["Hunter S. Thompson", "Middle"] in rows
      assert ["Jack Kerouac", "Middle"] in rows
    end
  end

  describe "whitelist validation" do
    test "allows SELECT queries" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT * FROM test_users LIMIT 1"))

      assert {:ok, %{columns: columns, rows: _}} = result
      assert "id" in columns
    end

    test "allows WITH queries" do
      sql = """
      WITH test AS (SELECT 1 as num)
      SELECT * FROM test
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:ok, %{columns: ["num"], rows: [[1]]}} = result
    end

    test "allows VALUES queries" do
      result = Runner.run_statement(@pg_adapter, Statement.new("VALUES (1, 'a'), (2, 'b')"))
      assert {:ok, %{columns: ["column1", "column2"], rows: [[1, "a"], [2, "b"]]}} = result
    end

    test "allows EXPLAIN queries" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("EXPLAIN SELECT * FROM test_users"))

      assert {:ok, %{columns: ["QUERY PLAN"], rows: rows}} = result
      refute Enum.empty?(rows)
    end

    test "rejects INSERT statements" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(
            "INSERT INTO test_users (name, email) VALUES ('test', 'test@example.com')"
          )
        )

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects UPDATE statements" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("UPDATE test_users SET name = 'Updated'"))

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects DELETE statements" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("DELETE FROM test_users WHERE id = 1"))

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects DROP statements" do
      result = Runner.run_statement(@pg_adapter, Statement.new("DROP TABLE test_users"))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects CREATE statements" do
      result = Runner.run_statement(@pg_adapter, Statement.new("CREATE TABLE new_table (id int)"))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects ALTER statements" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("ALTER TABLE test_users ADD COLUMN new_field text")
        )

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects TRUNCATE statements" do
      result = Runner.run_statement(@pg_adapter, Statement.new("TRUNCATE test_users"))
      assert {:error, "Only read-only queries are allowed"} = result
    end
  end

  describe "deny list validation" do
    test "detects dangerous keywords in string literals" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 'DROP TABLE users' as msg"))

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "detects dangerous keywords case-insensitively" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 'InSeRt INTO users' as msg"))

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "allows safe strings without dangerous keywords" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 'This is a safe message' as msg"))

      assert {:ok, %{columns: ["msg"], rows: [["This is a safe message"]]}} = result
    end
  end

  describe "single statement validation" do
    test "rejects multiple statements with semicolon" do
      result = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1; SELECT 2"))
      assert {:error, "Only a single statement is allowed"} = result
    end

    test "allows statement with trailing semicolon" do
      result = Runner.run_statement(@pg_adapter, Statement.new("SELECT * FROM test_users;"))
      assert {:ok, %{columns: columns, rows: rows}} = result
      refute Enum.empty?(columns)
      refute Enum.empty?(rows)
    end

    test "allows semicolon in string literals" do
      result = Runner.run_statement(@pg_adapter, Statement.new("SELECT 'test;value' as text"))
      assert {:ok, %{columns: ["text"], rows: [["test;value"]]}} = result
    end

    test "allows semicolon in double-quoted identifiers" do
      result = Runner.run_statement(@pg_adapter, Statement.new(~s[SELECT 'test' as "col;name"]))
      assert {:ok, %{columns: ["col;name"], rows: [["test"]]}} = result
    end

    test "allows semicolon in line comments" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT 1 as num -- comment with ; semicolon")
        )

      assert {:ok, %{columns: ["num"], rows: [[1]]}} = result
    end

    test "allows semicolon in block comments" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT /* comment ; with semicolon */ 1 as num")
        )

      assert {:ok, %{columns: ["num"], rows: [[1]]}} = result
    end

    test "allows semicolon in nested block comments" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT /* outer /* inner ; */ still outer ; */ 1 as num")
        )

      assert {:ok, %{columns: ["num"], rows: [[1]]}} = result
    end

    test "rejects statements hidden after an unclosed outer nested block comment" do
      # The outer comment is only closed by the second `*/`; without nested
      # comment tracking the parser would exit at the first `*/` and miss the
      # trailing `; SELECT 2` that sits outside the comment.
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 1 /* /* nested */ */ ; SELECT 2"))

      assert {:error, "Only a single statement is allowed"} = result
    end

    test "allows semicolon in PostgreSQL dollar-quoted strings" do
      result = Runner.run_statement(@pg_adapter, Statement.new("SELECT $$test;value$$ as text"))
      assert {:ok, %{columns: ["text"], rows: [["test;value"]]}} = result
    end

    test "allows semicolon in tagged dollar-quoted strings" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT $tag$test;value$tag$ as text"))

      assert {:ok, %{columns: ["text"], rows: [["test;value"]]}} = result
    end

    test "still rejects actual multiple statements" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 'test;ok' as text; SELECT 2"))

      assert {:error, "Only a single statement is allowed"} = result
    end

    test "allows complex mixed content with semicolons" do
      query = """
      SELECT
        'value;with;semicolons' as "col;name", -- comment ; here
        /* block ; comment */ 1 as num,
        $$dollar;quoted$$ as dq
      FROM test_users
      WHERE name = 'Jack Kerouac';
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(query))
      assert {:ok, %{columns: columns, rows: rows}} = result
      assert "col;name" in columns
      refute Enum.empty?(rows)
    end
  end

  describe "transaction and timeout behavior" do
    test "enforces read-only transaction by default" do
      sql = """
      WITH test AS (SELECT 1 as id)
      SELECT * FROM test
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:ok, %{columns: ["id"], rows: [[1]]}} = result
    end

    test "respects read_only: false option" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT COUNT(*) FROM test_users", []),
          read_only: false
        )

      assert {:ok, %{columns: ["count"], rows: [[3]]}} = result
    end

    test "respects custom statement timeout" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 1", []),
          statement_timeout_ms: 100
        )

      assert {:ok, %{columns: ["?column?"], rows: [[1]]}} = result
    end

    test "respects custom database timeout" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT COUNT(*) FROM test_users", []),
          timeout: 1000
        )

      assert {:ok, %{columns: ["count"], rows: [[3]]}} = result
    end
  end

  describe "write queries with read_only: false" do
    test "INSERT succeeds with read_only: false and returns result" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(
            "INSERT INTO test_users (name, email, age, active, metadata, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id, name, email",
            ["Ada Lovelace", "ada@math.org", 36, true, %{}, now, now]
          ),
          read_only: false
        )

      assert {:ok,
              %{columns: ["id", "name", "email"], rows: [[_id, "Ada Lovelace", "ada@math.org"]]}} =
               result
    end

    test "UPDATE succeeds with read_only: false and returns affected rows" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(
            "UPDATE test_users SET age = age + 1 WHERE active = true RETURNING id, name, age",
            []
          ),
          read_only: false
        )

      assert {:ok, %{columns: ["id", "name", "age"], rows: rows}} = result
      assert rows != []
    end

    test "DELETE succeeds with read_only: false and returns affected rows" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("DELETE FROM test_users WHERE active = false RETURNING id", []),
          read_only: false
        )

      assert {:ok, %{columns: ["id"], rows: rows}} = result
      assert rows != []
    end

    test "INSERT is still rejected with default opts (no regression)" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(
            "INSERT INTO test_users (name, email) VALUES ('test', 'test@example.com')"
          )
        )

      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "single-statement validation still enforced with read_only: false" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(
            "INSERT INTO test_users (name, email) VALUES ('a', 'a@a.com'); DELETE FROM test_users",
            []
          ),
          read_only: false
        )

      assert {:error, "Only a single statement is allowed"} = result
    end
  end

  describe "error handling" do
    test "handles syntax errors gracefully" do
      result = Runner.run_statement(@pg_adapter, Statement.new("SELECT * FROM"))
      assert {:error, msg} = result
      assert msg =~ "SQL syntax error:"
      assert msg =~ "syntax error at end of input" or msg =~ "syntax error at or near"
    end

    test "handles invalid table references" do
      result =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT * FROM non_existent_table"))

      assert {:error, msg} = result
      assert msg =~ "SQL error:"
      assert msg =~ "non_existent_table"
    end

    test "handles invalid column references", %{users: %{kerouac: kerouac}} do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT non_existent_column FROM test_users WHERE id = $1", [
            kerouac.id
          ])
        )

      assert {:error, msg} = result
      assert msg =~ "SQL error:"
      assert msg =~ "non_existent_column"
    end

    test "handles type mismatches" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT * FROM test_users WHERE id = $1", [
            "not_an_integer"
          ])
        )

      assert {:error, message} = result
      assert is_binary(message)
      assert message =~ "expected an integer"
    end

    test "handles empty result sets" do
      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT * FROM test_users WHERE id = -999")
        )

      assert {:ok, %{columns: columns, rows: []}} = result
      assert "id" in columns
    end

    test "handles NULL values" do
      user = Fixtures.insert_user(%{name: "Null Test", email: "null@test.com", age: nil})

      result =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT name, age FROM test_users WHERE id = $1", [
            user.id
          ])
        )

      assert {:ok, %{columns: ["name", "age"], rows: [["Null Test", nil]]}} = result
    end

    test "validates SQL string type" do
      assert_raise FunctionClauseError, fn ->
        Runner.run_statement(@pg_adapter, Statement.new(123, []))
      end
    end

    test "validates params list type" do
      assert_raise FunctionClauseError, fn ->
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 1", runtime_term("not_a_list")))
      end
    end
  end

  describe "complex query scenarios" do
    test "handles window functions" do
      sql = """
      SELECT
        title,
        view_count,
        ROW_NUMBER() OVER (ORDER BY view_count DESC) as rank
      FROM test_posts
      WHERE published = true
      ORDER BY rank
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["title", "view_count", "rank"], rows: rows}} = result
      assert length(rows) == 3
      assert [_, _, 1] = List.first(rows)
    end

    test "handles UNION queries" do
      sql = """
      SELECT name, 'user' as type FROM test_users WHERE active = true
      UNION
      SELECT title as name, 'post' as type FROM test_posts WHERE published = true
      ORDER BY name
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["name", "type"], rows: rows}} = result
      assert length(rows) > 3
    end

    test "handles date/time operations" do
      sql = """
      SELECT
        name,
        DATE(inserted_at) as created_date,
        EXTRACT(YEAR FROM inserted_at)::integer as year
      FROM test_users
      LIMIT 1
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["name", "created_date", "year"], rows: [[_, _, year]]}} = result
      assert is_integer(year)
    end

    test "handles string operations" do
      sql = """
      SELECT
        UPPER(name) as upper_name,
        LENGTH(name) as name_length,
        SUBSTRING(email FROM 1 FOR 5) as email_prefix
      FROM test_users
      WHERE active = false
      ORDER BY name
      LIMIT 1
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok,
              %{
                columns: ["upper_name", "name_length", "email_prefix"],
                rows: [[upper, length, prefix]]
              }} = result

      assert upper == "CHARLES BUKOWSKI"
      assert length == 16
      assert prefix == "hank@"
    end

    test "handles EXISTS subqueries" do
      sql = """
      SELECT name FROM test_users u
      WHERE EXISTS (
        SELECT 1 FROM test_posts p
        WHERE p.user_id = u.id AND p.published = true
      )
      ORDER BY name
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["name"], rows: rows}} = result
      assert ["Jack Kerouac"] in rows
      assert ["Charles Bukowski"] in rows
      refute ["Hunter S. Thompson"] in rows
    end

    test "handles DISTINCT queries" do
      sql = """
      SELECT DISTINCT active FROM test_users ORDER BY active
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["active"], rows: [[false], [true]]}} = result
    end

    test "handles LIMIT and OFFSET" do
      sql = """
      SELECT name FROM test_users
      ORDER BY name
      LIMIT 2 OFFSET 1
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok, %{columns: ["name"], rows: rows}} = result
      assert length(rows) == 2
      assert ["Hunter S. Thompson"] in rows
      assert ["Jack Kerouac"] in rows
    end
  end

  describe "compile!/2 with smart vars" do
    alias Lotus.Storage.Query

    test "expands vars into params" do
      q = %Query{
        statement: "SELECT * FROM test_users WHERE age > {{min_age}} AND active = {{is_active}}",
        variables: [
          %{name: "min_age", type: :number, default: "40"}
        ]
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"is_active" => true})

      assert sql =~ "$1"
      assert sql =~ "$2"
      assert params == [40, true]
    end

    test "raises when required var missing" do
      q = %Query{statement: "SELECT * FROM test_users WHERE age > {{min_age}}", variables: []}

      assert_raise ArgumentError, ~r/Missing required variable/, fn ->
        Query.compile!(q)
      end
    end
  end

  describe "CTE with destructive operations - PostgreSQL" do
    test "rejects CTE with DELETE operation" do
      sql = """
      WITH deleted_rows AS (
        DELETE FROM test_users WHERE active = false
        RETURNING *
      )
      SELECT COUNT(*) FROM deleted_rows
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects CTE with INSERT operation" do
      sql = """
      WITH inserted_users AS (
        INSERT INTO test_users (name, email, active)
        VALUES ('test', 'test@example.com', true)
        RETURNING *
      )
      SELECT * FROM inserted_users
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects CTE with UPDATE operation" do
      sql = """
      WITH updated_users AS (
        UPDATE test_users SET active = true
        WHERE active = false
        RETURNING *
      )
      SELECT COUNT(*) FROM updated_users
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects nested CTE with destructive operation" do
      sql = """
      WITH active_users AS (
        SELECT * FROM test_users WHERE active = true
      ),
      deleted_inactive AS (
        DELETE FROM test_users
        WHERE id NOT IN (SELECT id FROM active_users)
        RETURNING *
      )
      SELECT COUNT(*) FROM deleted_inactive
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects CTE with DROP operation" do
      sql = """
      WITH temp_data AS (
        SELECT * FROM test_users
      ),
      drop_result AS (
        DROP TABLE test_posts
      )
      SELECT * FROM temp_data
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects CTE with CREATE operation" do
      sql = """
      WITH new_table AS (
        CREATE TABLE temp_users AS SELECT * FROM test_users
      )
      SELECT 1
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "rejects CTE with TRUNCATE operation" do
      sql = """
      WITH truncated AS (
        TRUNCATE test_users
        RETURNING *
      )
      SELECT COUNT(*) FROM truncated
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    test "allows safe CTE with only SELECT operations" do
      sql = """
      WITH active_users AS (
        SELECT * FROM test_users WHERE active = true
      ),
      user_count AS (
        SELECT COUNT(*) as total FROM active_users
      )
      SELECT * FROM user_count
      """

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))
      assert {:ok, %{columns: ["total"], rows: _}} = result
    end
  end

  describe "CTE with destructive operations - SQLite" do
    @tag :sqlite
    test "rejects CTE with DELETE operation" do
      sql = """
      WITH deleted_rows AS (
        DELETE FROM test_users WHERE active = 0
        RETURNING *
      )
      SELECT COUNT(*) FROM deleted_rows
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    @tag :sqlite
    test "rejects CTE with INSERT operation" do
      sql = """
      WITH inserted_users AS (
        INSERT INTO test_users (name, email, active)
        VALUES ('test', 'test@example.com', 1)
        RETURNING *
      )
      SELECT * FROM inserted_users
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    @tag :sqlite
    test "rejects CTE with UPDATE operation" do
      sql = """
      WITH updated_users AS (
        UPDATE test_users SET active = 1
        WHERE active = 0
        RETURNING *
      )
      SELECT COUNT(*) FROM updated_users
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    @tag :sqlite
    test "rejects nested CTE with destructive operation" do
      sql = """
      WITH active_users AS (
        SELECT * FROM test_users WHERE active = 1
      ),
      deleted_inactive AS (
        DELETE FROM test_users
        WHERE id NOT IN (SELECT id FROM active_users)
        RETURNING *
      )
      SELECT COUNT(*) FROM deleted_inactive
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    @tag :sqlite
    test "rejects CTE with DROP operation" do
      sql = """
      WITH temp_data AS (
        SELECT * FROM test_users
      ),
      drop_result AS (
        DROP TABLE test_posts
      )
      SELECT * FROM temp_data
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    @tag :sqlite
    test "rejects CTE with CREATE operation" do
      sql = """
      WITH new_table AS (
        CREATE TABLE temp_users AS SELECT * FROM test_users
      )
      SELECT 1
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:error, "Only read-only queries are allowed"} = result
    end

    @tag :sqlite
    test "allows safe CTE with only SELECT operations" do
      sql = """
      WITH active_users AS (
        SELECT * FROM test_users WHERE active = 1
      ),
      user_count AS (
        SELECT COUNT(*) as total FROM active_users
      )
      SELECT * FROM user_count
      """

      result = Runner.run_statement(@sqlite_adapter, Statement.new(sql))
      assert {:ok, %{columns: ["total"], rows: _}} = result
    end
  end

  describe "Database-level protection tests" do
    test "PostgreSQL transaction_read_only prevents writes even if regex bypassed" do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL transaction_read_only = on")

        {:error, error} =
          Repo.query("INSERT INTO test_users (name, email) VALUES ('test', 'test@example.com')")

        assert %Postgrex.Error{} = error
        assert error.postgres.code == :read_only_sql_transaction
        assert error.postgres.message =~ "read-only"
      end)
    end

    @tag :sqlite
    test "SQLite PRAGMA query_only prevents writes (if supported)" do
      SqliteRepo.query!("PRAGMA query_only = ON")

      assert_raise Exqlite.Error, fn ->
        SqliteRepo.query!(
          "INSERT INTO test_users (name, email) VALUES ('test', 'test@example.com')"
        )
      end

      SqliteRepo.query!("PRAGMA query_only = OFF")
    end
  end

  describe "Result with additional attributes" do
    test "returns result with num_rows, duration_ms, and command attributes" do
      sql =
        "SELECT id, name, email, age, active, metadata, inserted_at, updated_at FROM test_users"

      result = Runner.run_statement(@pg_adapter, Statement.new(sql))

      assert {:ok,
              %Lotus.Result{
                columns: [
                  "id",
                  "name",
                  "email",
                  "age",
                  "active",
                  "metadata",
                  "inserted_at",
                  "updated_at"
                ],
                rows: rows,
                num_rows: num_rows,
                duration_ms: duration_ms,
                command: command,
                meta: meta
              }} = result

      assert is_list(rows)
      assert is_integer(num_rows)
      assert num_rows >= 0
      assert is_integer(duration_ms)
      assert duration_ms >= 0
      assert is_binary(command)
      assert command == "select"
      assert is_map(meta)
      assert is_integer(meta.connection_id)
      assert is_list(meta.messages)
    end
  end

  describe "UUID column handling" do
    setup do
      uuid1 = Ecto.UUID.generate()
      uuid2 = Ecto.UUID.generate()
      {:ok, uuid1_bin} = Ecto.UUID.dump(uuid1)
      {:ok, uuid2_bin} = Ecto.UUID.dump(uuid2)

      Repo.query!(
        "INSERT INTO test_uuid_records (id, name, ref_id) VALUES ($1, $2, $3)",
        [uuid1_bin, "Record A", uuid2_bin]
      )

      Repo.query!(
        "INSERT INTO test_uuid_records (id, name, ref_id) VALUES ($1, $2, NULL)",
        [uuid2_bin, "Record B"]
      )

      %{uuid1: uuid1, uuid2: uuid2}
    end

    test "returns raw UUID binaries in result rows", %{uuid1: uuid1} do
      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT id, name FROM test_uuid_records WHERE name = $1", [
            "Record A"
          ])
        )

      assert %{columns: ["id", "name"], rows: [[id_bin, "Record A"]]} = result
      # Postgrex returns UUIDs as raw 16-byte binaries
      assert byte_size(id_bin) == 16
      {:ok, loaded} = Ecto.UUID.load(id_bin)
      assert loaded == uuid1
    end

    test "result with UUID columns is JSON-encodable via to_encodable", %{
      uuid1: uuid1,
      uuid2: uuid2
    } do
      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT id, name, ref_id FROM test_uuid_records ORDER BY name")
        )

      # to_encodable normalizes UUIDs to strings
      encodable = Lotus.Result.to_encodable(result)
      encoded = Lotus.JSON.encode!(encodable)
      decoded = Lotus.JSON.decode!(encoded)

      assert [[id_a, "Record A", ref_a], [id_b, "Record B", nil]] = decoded["rows"]
      assert id_a == uuid1
      assert ref_a == uuid2
      assert id_b == uuid2
    end
  end

  describe "column masking" do
    setup do
      Mimic.copy(Lotus.Config)
      :ok
    end

    test "partial mask hides every byte of a value that is not valid UTF-8" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"blob", [mask: {:partial, keep_last: 4}]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT '\\xdeadbeef'::bytea AS blob")
        )

      assert %{rows: [["****"]]} = result
    end

    test "partial mask hides a value no longer than the kept tail" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"pin", [mask: {:partial, keep_last: 4}]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT '1234'::text AS pin")
        )

      assert %{rows: [["****"]]} = result
    end

    test "partial mask still keeps the tail of a valid UTF-8 value" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"secret", [mask: {:partial, keep_last: 4}]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT 'supersecret'::text AS secret")
        )

      assert %{rows: [["*******cret"]]} = result
    end

    test "partial mask renders a jsonb value instead of failing the query" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"doc", [mask: {:partial, keep_last: 4}]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(~s|SELECT '{"a":1}'::jsonb AS doc|)
        )

      assert %{rows: [["***\":1}"]]} = result
    end

    test "sha256 mask hashes a jsonb value instead of failing the query" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"doc", [mask: :sha256]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new(~s|SELECT '{"a":1}'::jsonb AS doc|)
        )

      assert %{rows: [[digest]]} = result
      assert digest =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "sha256 mask hashes the stored bytes of a value that is not valid UTF-8" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"blob", [mask: :sha256]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @pg_adapter,
          Statement.new("SELECT '\\xdeadbeef'::bytea AS blob")
        )

      expected = :crypto.hash(:sha256, <<222, 173, 190, 239>>) |> Base.encode16(case: :lower)
      assert %{rows: [[^expected]]} = result
    end

    @tag :sqlite
    test "partial mask hides every byte of a SQLite blob" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"blob", [mask: {:partial, keep_last: 4}]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @sqlite_adapter,
          Statement.new("SELECT x'deadbeef' AS blob")
        )

      assert %{rows: [["****"]]} = result
    end

    @tag :mysql
    test "partial mask hides every byte of a MySQL binary value" do
      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"payload", [mask: {:partial, keep_last: 4}]}]
      end)

      {:ok, result} =
        Runner.run_statement(
          @mysql_adapter,
          Statement.new("SELECT CAST(0xDEADBEEF AS BINARY) AS payload")
        )

      assert %{rows: [["****"]]} = result
    end
  end

  # Hands the value over as an opaque term() so Elixir 1.20's type checker can't
  # statically reject the deliberately-invalid argument below. The point is to
  # exercise the *runtime* guard, which is what real (dynamic) callers hit.
  @spec runtime_term(term()) :: term()
  defp runtime_term(value), do: value

  describe "preflight relations between statements" do
    setup do
      Mimic.copy(Lotus.Config)
      Mimic.copy(Lotus.Middleware)
      Mimic.copy(Lotus.Source.Adapter)
      :ok
    end

    # `CAST(email AS integer)` plans fine and fails only once a row is
    # evaluated, so preflight passes and records its relations first. The
    # issue's `1 / 0` cannot stand in for it: constant folding makes that fail
    # inside preflight's own EXPLAIN, so it never reaches the path covered here.
    @failing_statement "SELECT CAST(email AS integer) AS boom FROM test_users"

    test "clears the relations of a statement that fails during execution" do
      assert {:error, _} = Runner.run_statement(@pg_adapter, Statement.new(@failing_statement))

      assert Relations.get() == []
    end

    test "a failed statement does not lend its tables to the next statement" do
      show = Statement.new("SHOW search_path")

      assert {:ok, %{rows: [[unmasked_path]]}} = Runner.run_statement(@pg_adapter, show)

      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"test_users", "search_path", [mask: {:fixed, "REDACTED"}]}]
      end)

      assert {:error, _} = Runner.run_statement(@pg_adapter, Statement.new(@failing_statement))

      # `SHOW` skips preflight — see `EctoAdapter.do_needs_preflight?/2` — so it
      # never overwrites what the failed statement left behind. Its column must
      # not take the rule written for `test_users`.
      assert {:ok, %{columns: ["search_path"], rows: [[path]]}} =
               Runner.run_statement(@pg_adapter, show)

      assert path == unmasked_path
    end

    # `exec_read_only/3` rescues, and `Middleware.run/2` turns a raising plug
    # into `{:halt, _}`, so no exception escapes `run_statement/3` as the code
    # stands. Stubbing both boundaries forces the raise this pins: whatever a
    # raising run leaves in the process dictionary, the next statement's column
    # policies come from its own preflight and nothing else.
    test "a raise does not lend relations to the next statement" do
      Lotus.Middleware
      |> stub(:run, fn
        :before_query, payload ->
          Relations.put([{"public", "test_users"}])
          {:cont, payload}

        _event, payload ->
          {:cont, payload}
      end)

      Lotus.Source.Adapter
      |> stub(:sanitize_query, fn _adapter, _statement, _opts -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn ->
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
      end

      Lotus.Source.Adapter
      |> stub(:sanitize_query, fn _adapter, _statement, _opts -> :ok end)

      Lotus.Config
      |> stub(:column_rules_for_source_name, fn _source ->
        [{"test_users", "search_path", [mask: {:fixed, "REDACTED"}]}]
      end)

      # `SHOW` skips preflight, so the stranded value is the only candidate
      # for its column policy — and it must not be used.
      assert {:ok, %{columns: ["search_path"], rows: [[path]]}} =
               Runner.run_statement(@pg_adapter, Statement.new("SHOW search_path"))

      assert path != "REDACTED"
    end
  end
end
