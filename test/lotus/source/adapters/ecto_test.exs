defmodule Lotus.Source.Adapters.EctoTest.SpecDialect do
  @moduledoc false
  # An external dialect whose lexical rules differ from ANSI SQL, declared
  # the way a dialect outside Lotus declares them: a dialect_spec.

  def query_language, do: "sql:spec_test"

  def editor_config do
    %{
      language: "sql:spec_test",
      keywords: [],
      types: [],
      functions: [],
      context_boundaries: [],
      dialect_spec: %{identifier_quotes: "\"`", hash_comments: true, backslash_escapes: true}
    }
  end

  def denied_functions, do: ["read_file"]
end

defmodule Lotus.Source.Adapters.EctoTest do
  use Lotus.Case, async: true

  alias Lotus.Query.Filter
  alias Lotus.Query.Statement
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Source.Adapters.MySQL
  alias Lotus.Source.Adapters.Postgres
  alias Lotus.Source.Adapters.SQLite3
  alias Lotus.Test.MysqlRepo
  alias Lotus.Test.Repo
  alias Lotus.Test.SqliteRepo

  describe "wrap/2" do
    test "creates an Adapter struct with correct fields" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert %Adapter{} = adapter
      assert adapter.name == "main"
      assert adapter.module == Lotus.Source.Adapters.Postgres
      assert adapter.state == Repo
      assert adapter.source_type == :postgres
    end
  end

  describe "detect_source_type/1" do
    test "detects Postgres adapter" do
      assert EctoAdapter.detect_source_type(Repo) == :postgres
    end

    test "detects SQLite adapter" do
      assert EctoAdapter.detect_source_type(Lotus.Test.SqliteRepo) == :sqlite
    end

    test "detects MySQL adapter" do
      assert EctoAdapter.detect_source_type(Lotus.Test.MysqlRepo) == :mysql
    end
  end

  describe "source_type/0" do
    test "returns the source type from the wrapped repo" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert Adapter.source_type(adapter) == :postgres
    end
  end

  describe "supports_feature?/1" do
    test "postgres supports search_path" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert Adapter.supports_feature?(adapter, :search_path)
    end

    test "postgres supports json" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert Adapter.supports_feature?(adapter, :json)
    end

    test "postgres supports arrays" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert Adapter.supports_feature?(adapter, :arrays)
    end

    test "postgres does not support unknown features" do
      adapter = EctoAdapter.wrap("main", Repo)
      refute Adapter.supports_feature?(adapter, :time_travel)
    end
  end

  describe "introspection callbacks" do
    test "list_schemas/1 returns {:ok, _} tuple" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert {:ok, schemas} = Adapter.list_schemas(adapter)
      assert is_list(schemas)
      assert "public" in schemas
    end

    test "list_tables/3 returns {:ok, _} tuple" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert {:ok, tables} = Adapter.list_tables(adapter, ["public"], include_views: false)
      assert is_list(tables)
    end

    test "describe_table/3 returns {:ok, _} tuple" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert {:ok, columns} = Adapter.describe_table(adapter, "public", "lotus_queries")
      assert is_list(columns)
    end

    test "resolve_table_namespace/3 returns {:ok, _} tuple" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert {:ok, schema} = Adapter.resolve_table_namespace(adapter, "lotus_queries", ["public"])
      assert schema == "public"
    end
  end

  describe "SQL generation callbacks" do
    test "quote_identifier/1 uses Postgres double-quoting" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert ~s("users") == Adapter.quote_identifier(adapter, "users")
    end
  end

  describe "safety callbacks" do
    test "builtin_denies/1 returns deny rules" do
      adapter = EctoAdapter.wrap("main", Repo)
      denies = Adapter.builtin_denies(adapter)
      assert is_list(denies)

      # Compare by regex source — `Regex` structs aren't
      # reliably comparable (the compiled pattern differs under OTP 28's PCRE2),
      # so `~r/.*/ in denies` fails even when the rule is present.
      assert Enum.any?(denies, fn
               {"pg_catalog", %Regex{} = re} -> Regex.source(re) == ".*"
               _ -> false
             end)
    end

    test "builtin_schema_denies/1 returns schema deny patterns" do
      adapter = EctoAdapter.wrap("main", Repo)
      denies = Adapter.builtin_schema_denies(adapter)
      assert is_list(denies)
      assert "pg_catalog" in denies
    end

    test "default_schemas/1 returns default schemas" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert ["public"] == Adapter.default_schemas(adapter)
    end
  end

  describe "lifecycle callbacks" do
    test "health_check/1 succeeds for running repo" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert :ok = Adapter.health_check(adapter)
    end

    test "disconnect/1 returns :ok (static repos managed by supervisor)" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert :ok = Adapter.disconnect(adapter)
    end
  end

  describe "execute_query/4" do
    test "executes a simple query and returns result map" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, result} = Adapter.execute_query(adapter, "SELECT 1 AS num", [], [])
      assert result.columns == ["num"]
      assert result.rows == [[1]]
      assert result.num_rows == 1
    end

    test "returns error for invalid SQL" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, _reason} = Adapter.execute_query(adapter, "INVALID SQL", [], [])
    end

    test "respects search_path option" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, result} =
               Adapter.execute_query(adapter, "SELECT 1 AS num", [], search_path: "public")

      assert result.columns == ["num"]
    end
  end

  describe "transaction/3" do
    test "executes a function in a transaction" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, result} =
               Adapter.transaction(
                 adapter,
                 fn repo ->
                   repo.query!("SELECT 42 AS answer")
                 end,
                 []
               )

      assert %{rows: [[42]]} = result
    end

    test "a postgres read-only run rolls back what it set for the session" do
      adapter = Postgres.wrap("pg", Repo)
      setting = "SELECT current_setting('lotus.test_setting', true)"

      assert {:ok, %{rows: [["leaked"]]}} =
               Adapter.transaction(
                 adapter,
                 fn repo ->
                   repo.query!("SELECT set_config('lotus.test_setting', 'leaked', false)")
                 end,
                 read_only: true
               )

      assert %{rows: [[value]]} = Repo.query!(setting)
      assert value in [nil, ""]

      assert {:ok, _} =
               Adapter.transaction(
                 adapter,
                 fn repo ->
                   repo.query!("SELECT set_config('lotus.test_setting', 'kept', false)")
                 end,
                 read_only: false
               )

      assert %{rows: [["kept"]]} = Repo.query!(setting)
    end

    test "a postgres read-only run still returns an error as an error" do
      adapter = Postgres.wrap("pg", Repo)

      assert {:error, "SQL error: " <> _} =
               Adapter.execute_query(adapter, "SELECT * FROM no_such_table", [], [])
    end
  end

  describe "sanitize_query/3" do
    test "allows a single SELECT statement" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert :ok = Adapter.sanitize_query(adapter, Statement.new("SELECT 1"), [])
    end

    test "allows a write keyword inside a string literal, a comment or a quoted identifier" do
      adapter = Postgres.wrap("pg", Repo)

      for sql <- [
            "SELECT 1 FROM events WHERE name = 'ai.call'",
            "SELECT 'please delete me'",
            "SELECT 1 -- delete",
            "SELECT 1 /* drop table users */",
            ~s(SELECT "update" FROM t)
          ] do
        assert :ok = Adapter.sanitize_query(adapter, Statement.new(sql), []), sql
      end
    end

    test "rejects a write keyword in code" do
      adapter = Postgres.wrap("pg", Repo)

      for sql <- ["DELETE FROM users", "SELECT 1 FROM t WHERE 'x' = 'x' AND CALL"] do
        assert {:error, "Only read-only queries are allowed"} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), []),
               sql
      end
    end

    test "rejects commands that change the session or the transaction" do
      adapter = Postgres.wrap("pg", Repo)

      for sql <- [
            "SET statement_timeout = 1",
            "set search_path = other",
            "RESET ALL",
            "LISTEN channel",
            "COPY test_users TO STDOUT",
            "DO $$ BEGIN PERFORM 1; END $$",
            "DECLARE c CURSOR WITH HOLD FOR SELECT 1",
            "COMMIT",
            "PREPARE p AS SELECT 1"
          ] do
        assert {:error, "Only read-only queries are allowed: " <> _} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), []),
               sql
      end

      assert :ok = Adapter.sanitize_query(adapter, Statement.new("SET x = 1"), read_only: false)
    end

    test "postgres rejects functions with effects beyond the transaction" do
      adapter = Postgres.wrap("pg", Repo)

      for sql <- [
            "SELECT set_config('statement_timeout', '1', false)",
            "SELECT pg_catalog.set_config('search_path', 'other', false)",
            ~s(SELECT "set_config"('search_path', 'other', false\)),
            "SELECT set_config /* hi */ ('search_path', 'other', false)",
            "SELECT pg_advisory_lock(42)",
            "SELECT pg_try_advisory_lock_shared(42)",
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity",
            "SELECT PG_CANCEL_BACKEND(1)",
            "SELECT dblink_exec('dbname=app', 'DELETE FROM users')",
            "SELECT lo_export(1, '/tmp/x')",
            "SELECT pg_read_file('/etc/passwd')",
            "SELECT query_to_xml('SELECT * FROM secrets', true, false, '')",
            "SELECT pg_notify('c', 'x')"
          ] do
        assert {:error, "Only read-only queries are allowed: " <> _} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), []),
               sql
      end

      for sql <- [
            "SELECT set_config FROM t",
            "SELECT 'pg_advisory_lock(1)'",
            "SELECT current_setting('search_path')",
            "SELECT 1 -- set_config('a', 'b', false)"
          ] do
        assert :ok = Adapter.sanitize_query(adapter, Statement.new(sql), []), sql
      end
    end

    test "mysql rejects named locks, files and OUTFILE" do
      adapter = MySQL.wrap("my", MysqlRepo)

      for sql <- [
            "SELECT GET_LOCK('x', 10)",
            "SELECT `load_file`('/etc/passwd')",
            "SELECT * FROM t INTO OUTFILE '/tmp/x'",
            "SET @@session.sql_mode = ''",
            "USE other_db"
          ] do
        assert {:error, "Only read-only queries are allowed" <> _} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), []),
               sql
      end
    end

    test "sqlite rejects extensions and PRAGMAs that set a value" do
      adapter = SQLite3.wrap("lite", SqliteRepo)

      for sql <- [
            "SELECT load_extension('x')",
            "PRAGMA query_only = 0",
            "PRAGMA main.journal_mode = DELETE",
            "PRAGMA foreign_keys(0)",
            "PRAGMA 'ignore_check_constraints' = 1",
            "PRAGMA main.'case_sensitive_like' = 1",
            "PRAGMA 'main'.'busy_timeout'(0)",
            ~s(PRAGMA"query_only"=0),
            "PRAGMA[query_only]=0",
            "PRAGMA `query_only` = 0",
            "PRAGMA 'two words' = 1",
            "PRAGMA - 1",
            ~s(DETACH"other")
          ] do
        assert {:error, "Only read-only queries are allowed" <> _} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), []),
               sql
      end

      for sql <- [
            "PRAGMA table_info(users)",
            "PRAGMA foreign_keys",
            "PRAGMA 'table_info'('users')",
            ~s(PRAGMA main."foreign_keys")
          ] do
        assert :ok = Adapter.sanitize_query(adapter, Statement.new(sql), []), sql
      end
    end

    test "postgres reads a Unicode-escaped function name as the name it spells" do
      adapter = Postgres.wrap("pg", Repo)

      for sql <- [
            ~S|SELECT U&"set\005fconfig"('a.b', 'c', false)|,
            ~S|SELECT u&"set_config"('a.b', 'c', false)|,
            ~S|SELECT pg_catalog.U&"set\005fconfig"('a.b', 'c', false)|,
            ~S|SELECT U&"set!005fconfig" UESCAPE '!'('a.b', 'c', false)|,
            ~S|SELECT U&"pg\+00005fterminate_backend"(1)|
          ] do
        assert {:error, "Only read-only queries are allowed: " <> _} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), []),
               sql
      end

      for sql <- [~S|SELECT U&"d\0061ta" FROM t|, ~S|SELECT U&"bad\zz"(1)|] do
        assert :ok = Adapter.sanitize_query(adapter, Statement.new(sql), []), sql
      end
    end

    test "rejects multiple statements" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, "Only a single statement is allowed"} =
               Adapter.sanitize_query(adapter, Statement.new("SELECT 1; DROP TABLE users"), [])
    end

    test "rejects a statement that doesn't close what it opens, or closes what it didn't" do
      for {adapter, sql} <- [
            {EctoAdapter.wrap("main", Repo), "SELECT 1) AS x --"},
            {EctoAdapter.wrap("main", Repo), "SELECT (1"},
            {EctoAdapter.wrap("main", Repo), "SELECT 1 /* note"},
            {Postgres.wrap("pg", Repo), "SELECT 1 /* a /* b */"},
            {SQLite3.wrap("lite", SqliteRepo), "SELECT 1 /*"}
          ] do
        assert {:error, "Query has unbalanced parentheses or an unclosed comment"} =
                 Adapter.sanitize_query(adapter, Statement.new(sql), read_only: false),
               sql
      end
    end

    test "passes parentheses and comments inside literals, identifiers and comments" do
      for {adapter, sql} <- [
            {EctoAdapter.wrap("main", Repo), "SELECT ')' AS x, \"(\" FROM t -- )"},
            {EctoAdapter.wrap("main", Repo), "SELECT (1) /* ( */"},
            {Postgres.wrap("pg", Repo), "SELECT 1 /* a /* b */ c */"},
            {Postgres.wrap("pg", Repo), "SELECT $$)$$"},
            {SQLite3.wrap("lite", SqliteRepo), "SELECT 1 /* a /* b */"}
          ] do
        assert :ok = Adapter.sanitize_query(adapter, Statement.new(sql), []), sql
      end
    end

    test "postgres nests block comments when looking for a second statement" do
      adapter = Postgres.wrap("pg", Repo)

      assert :ok =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("SELECT 1 /* a /* b */ ; SELECT 2 */"),
                 []
               )
    end

    test "mysql ends a block comment at the first close marker" do
      adapter = MySQL.wrap("my", MysqlRepo)

      assert {:error, "Only a single statement is allowed"} =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("SELECT 1 /* a /* b */ ; SELECT 2 */"),
                 []
               )
    end

    test "sqlite ends a block comment at the first close marker" do
      adapter = SQLite3.wrap("lite", SqliteRepo)

      assert {:error, "Only a single statement is allowed"} =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("SELECT 1 /* a /* b */ ; SELECT 2 */"),
                 []
               )
    end

    test "mysql allows a semicolon inside a hash comment" do
      adapter = MySQL.wrap("my", MysqlRepo)

      assert :ok =
               Adapter.sanitize_query(adapter, Statement.new("SELECT 1 # ; not a statement"), [])
    end

    test "mysql allows a semicolon after a backslash-escaped quote inside a literal" do
      adapter = MySQL.wrap("my", MysqlRepo)

      assert :ok =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new(~S|SELECT 'it\'s; fine' AS s|),
                 []
               )
    end

    test "mysql allows a semicolon inside a backtick identifier" do
      adapter = MySQL.wrap("my", MysqlRepo)

      assert :ok = Adapter.sanitize_query(adapter, Statement.new("SELECT `a;b` FROM t"), [])
    end

    test "reads an external dialect's statements with the lexical rules of its dialect_spec" do
      dialect = Lotus.Source.Adapters.EctoTest.SpecDialect

      # A denied call that ANSI rules miss: after a backslash-escaped quote,
      # on the line after a # comment, or quoted with backticks.
      for sql <- [
            ~S"SELECT 'it\'s', read_file('x') -- '",
            "SELECT 1 # don't\n, read_file('x')",
            "SELECT `read_file`('x')"
          ] do
        assert {:error, "Only read-only queries are allowed: read_file() is not"} =
                 EctoAdapter.do_sanitize_query(dialect, Statement.new(sql), []),
               sql
      end

      # And no call where the dialect has a comment, a literal or a name.
      for sql <- [
            "SELECT 1 # read_file('x')",
            ~S"SELECT 'it\'s read_file(''x'')' AS s",
            "SELECT `read_file` FROM t"
          ] do
        assert :ok = EctoAdapter.do_sanitize_query(dialect, Statement.new(sql), []), sql
      end
    end

    test "blocks DML when read_only is true" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, "Only read-only queries are allowed"} =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("INSERT INTO users VALUES (1)"),
                 read_only: true
               )
    end

    test "allows DML when read_only is false" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert :ok =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("INSERT INTO users VALUES (1)"),
                 read_only: false
               )
    end

    test "defaults to read_only: true" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, "Only read-only queries are allowed"} =
               Adapter.sanitize_query(adapter, Statement.new("DELETE FROM users"), [])
    end
  end

  describe "transform_bound_query/3" do
    test "passes through statement unchanged" do
      adapter = EctoAdapter.wrap("main", Repo)
      statement = Statement.new("SELECT 1", [42])
      assert ^statement = Adapter.transform_bound_query(adapter, statement, [])
    end
  end

  describe "transform_statement/2" do
    test "applies dialect-level statement rewriting" do
      # Postgres's transform_statement rewrites interval syntax, among other things.
      adapter = EctoAdapter.wrap("main", Repo)
      out = Adapter.transform_statement(adapter, Statement.new("SELECT 1"))
      assert %Statement{body: text} = out
      assert is_binary(text)
    end
  end

  describe "extract_accessed_resources/2" do
    test "extracts postgres relations via EXPLAIN" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, relations} =
               Adapter.extract_accessed_resources(
                 adapter,
                 Statement.new("SELECT * FROM lotus_queries")
               )

      assert MapSet.member?(relations, {"public", "lotus_queries"})
    end

    test "returns error for invalid SQL" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, _reason} =
               Adapter.extract_accessed_resources(
                 adapter,
                 Statement.new("SELECT * FROM nonexistent_xyz")
               )
    end
  end

  describe "apply_pagination/3" do
    test "wraps query with LIMIT/OFFSET for postgres" do
      adapter = EctoAdapter.wrap("main", Repo)

      paged =
        Adapter.apply_pagination(adapter, Statement.new("SELECT * FROM users"),
          limit: 10,
          offset: 0
        )

      assert paged.body =~ "LIMIT"
      assert paged.body =~ "OFFSET"
      assert paged.params == [10, 0]
      refute Map.has_key?(paged.meta, :count_spec)
    end

    test "places a count_spec in meta when count: :exact" do
      adapter = EctoAdapter.wrap("main", Repo)

      paged =
        Adapter.apply_pagination(adapter, Statement.new("SELECT * FROM users"),
          limit: 10,
          offset: 0,
          count: :exact
        )

      assert %{query: count_query, params: []} = paged.meta[:count_spec]
      assert count_query =~ "COUNT(*)"
    end

    test "no count_spec in meta when count: :none" do
      adapter = EctoAdapter.wrap("main", Repo)

      paged =
        Adapter.apply_pagination(adapter, Statement.new("SELECT * FROM users"),
          limit: 10,
          offset: 0,
          count: :none
        )

      refute Map.has_key?(paged.meta, :count_spec)
    end
  end

  describe "dispatch helpers for optional callbacks" do
    test "sanitize_query returns :ok for adapter without the callback" do
      adapter = %Adapter{
        name: "stub",
        module: Lotus.Test.StubAdapter,
        state: nil,
        source_type: :other
      }

      assert :ok = Adapter.sanitize_query(adapter, Statement.new("anything"), [])
    end

    test "transform_bound_query passes through for adapter without the callback" do
      adapter = %Adapter{
        name: "stub",
        module: Lotus.Test.StubAdapter,
        state: nil,
        source_type: :other
      }

      statement = Statement.new("SELECT 1")
      assert ^statement = Adapter.transform_bound_query(adapter, statement, [])
    end

    test "extract_accessed_resources returns {:unrestricted, _} for adapter without the callback" do
      adapter = %Adapter{
        name: "stub",
        module: Lotus.Test.StubAdapter,
        state: nil,
        source_type: :other
      }

      assert {:unrestricted, _reason} =
               Adapter.extract_accessed_resources(adapter, Statement.new("SELECT 1"))
    end

    test "apply_pagination passes through for adapter without the callback" do
      adapter = %Adapter{
        name: "stub",
        module: Lotus.Test.StubAdapter,
        state: nil,
        source_type: :other
      }

      statement = Statement.new("SELECT 1")
      assert ^statement = Adapter.apply_pagination(adapter, statement, [])
    end
  end

  describe "error handling" do
    test "format_error/1 formats exceptions" do
      adapter = EctoAdapter.wrap("main", Repo)
      error = %RuntimeError{message: "boom"}
      assert is_binary(Adapter.format_error(adapter, error))
    end
  end

  describe "validate_statement/3" do
    test "returns :ok for a parseable SQL statement" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert :ok = Adapter.validate_statement(adapter, Statement.new("SELECT 1"), [])
    end

    test "returns {:error, reason} for syntactically invalid SQL" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, reason} =
               Adapter.validate_statement(adapter, Statement.new("SELEC 1"), [])

      assert is_binary(reason)
    end

    test "neutralizes {{var}} placeholders so the raw template validates" do
      adapter = EctoAdapter.wrap("main", Repo)

      # Unbound {{id}} → NULL during validation.
      assert :ok =
               Adapter.validate_statement(
                 adapter,
                 Statement.new("SELECT * FROM test_users WHERE id = {{id}}"),
                 []
               )
    end

    test "strips [[...]] optional clauses so the template validates" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert :ok =
               Adapter.validate_statement(
                 adapter,
                 Statement.new("SELECT * FROM test_users [[WHERE name = {{name}}]]"),
                 []
               )
    end
  end

  describe "parse_qualified_name/2" do
    test "splits a schema-qualified name into [schema, table]" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert {:ok, ["public", "users"]} = Adapter.parse_qualified_name(adapter, "public.users")
    end

    test "returns [name] for an unqualified name" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert {:ok, ["users"]} = Adapter.parse_qualified_name(adapter, "users")
    end
  end

  describe "validate_identifier/3" do
    setup do
      {:ok, adapter: EctoAdapter.wrap("main", Repo)}
    end

    test "accepts a simple ASCII identifier", %{adapter: adapter} do
      assert :ok = Adapter.validate_identifier(adapter, :table, "users")
      assert :ok = Adapter.validate_identifier(adapter, :schema, "public")
      assert :ok = Adapter.validate_identifier(adapter, :column, "email_address")
    end

    test "rejects identifiers with spaces or punctuation", %{adapter: adapter} do
      assert {:error, msg} = Adapter.validate_identifier(adapter, :table, "users table")
      assert msg =~ "Invalid table name"
    end

    test "rejects identifiers starting with a digit", %{adapter: adapter} do
      assert {:error, _msg} = Adapter.validate_identifier(adapter, :column, "1col")
    end

    test "accepts identifiers with underscores and digits (after first char)", %{adapter: adapter} do
      assert :ok = Adapter.validate_identifier(adapter, :column, "col_1")
      assert :ok = Adapter.validate_identifier(adapter, :column, "_private")
    end
  end

  describe "supported_filter_operators/1" do
    test "returns the full Lotus.Query.Filter operator set" do
      adapter = EctoAdapter.wrap("main", Repo)
      ops = Adapter.supported_filter_operators(adapter)

      assert is_list(ops)
      assert Enum.sort(ops) == Enum.sort(Filter.operators())
    end

    @tag :sqlite
    test "SQLite dialect reports the same set" do
      adapter = EctoAdapter.wrap("sqlite", Lotus.Test.SqliteRepo)
      ops = Adapter.supported_filter_operators(adapter)

      assert Enum.sort(ops) == Enum.sort(Filter.operators())
    end

    @tag :mysql
    test "MySQL dialect reports the same set" do
      adapter = EctoAdapter.wrap("mysql", Lotus.Test.MysqlRepo)
      ops = Adapter.supported_filter_operators(adapter)

      assert Enum.sort(ops) == Enum.sort(Filter.operators())
    end

    test "a dialect that does not declare its operators has no text operators" do
      ops = EctoAdapter.do_supported_filter_operators(String)

      assert :like in ops
      assert Enum.sort(ops) == Enum.sort(Filter.operators() -- Filter.text_operators())
    end
  end

  describe "prepare_for_analysis/2" do
    test "neutralizes {{var}} placeholders to NULL" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, %Statement{body: prepared}} =
               Adapter.prepare_for_analysis(
                 adapter,
                 Statement.new("SELECT * FROM test_users WHERE id = {{id}}")
               )

      assert prepared =~ "id = NULL"
      refute prepared =~ "{{id}}"
    end

    test "strips [[...]] brackets while keeping inner content visible to the planner" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, %Statement{body: prepared}} =
               Adapter.prepare_for_analysis(
                 adapter,
                 Statement.new("SELECT * FROM test_users [[WHERE name = {{name}}]]")
               )

      assert prepared =~ "WHERE name = NULL"
      refute prepared =~ "[["
      refute prepared =~ "]]"
    end

    test "empties :params — the prepared statement carries no bound values" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, %Statement{params: []}} =
               Adapter.prepare_for_analysis(
                 adapter,
                 Statement.new("SELECT 1", [1, 2, 3])
               )
    end

    test "returns the prepared statement validatable by query_plan/3" do
      adapter = EctoAdapter.wrap("main", Repo)

      {:ok, prepared} =
        Adapter.prepare_for_analysis(
          adapter,
          Statement.new("SELECT id FROM test_users WHERE id = {{id}} [[AND name = {{name}}]]")
        )

      assert {:ok, _plan} = Adapter.query_plan(adapter, prepared, [])
    end
  end

  describe "sanitize_query/3 deny list on code tokens" do
    test "allows a column named after a denied keyword" do
      adapter = Postgres.wrap("pg", Repo)

      assert :ok =
               Adapter.sanitize_query(adapter, Statement.new(~s|SELECT "lock" FROM doors|), [])
    end

    test "allows a denied keyword inside a string literal" do
      adapter = Postgres.wrap("pg", Repo)

      assert :ok =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("SELECT * FROM audit WHERE action = 'DELETE'"),
                 []
               )
    end

    test "allows a denied keyword inside a comment" do
      adapter = Postgres.wrap("pg", Repo)

      assert :ok =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new("-- last UPDATE by cron\nSELECT 1 /* DROP */"),
                 []
               )
    end

    test "still rejects a write statement" do
      adapter = Postgres.wrap("pg", Repo)

      assert {:error, "Only read-only queries are allowed"} =
               Adapter.sanitize_query(adapter, Statement.new("DELETE FROM users"), [])
    end

    test "rejects a write hidden inside an optional block" do
      adapter = Postgres.wrap("pg", Repo)

      assert {:error, "Only read-only queries are allowed"} =
               Adapter.sanitize_query(
                 adapter,
                 Statement.new(
                   "SELECT * FROM t [[WHERE id IN (DELETE FROM users RETURNING id)]]"
                 ),
                 []
               )
    end
  end

  describe "substitute_variable/5 on tokens" do
    test "binds the placeholder in code, not the one in a comment" do
      adapter = Postgres.wrap("pg", Repo)

      assert {:ok, %Statement{body: body, params: [7]}} =
               Adapter.substitute_variable(
                 adapter,
                 Statement.new("-- {{id}}\nSELECT {{id}}"),
                 "id",
                 7,
                 :integer
               )

      assert body == "-- {{id}}\nSELECT $1::integer"
    end

    test "binds a list placeholder in code, not the one in a comment" do
      adapter = Postgres.wrap("pg", Repo)

      assert {:ok, %Statement{body: body, params: [1, 2]}} =
               Adapter.substitute_list_variable(
                 adapter,
                 Statement.new("-- {{ids}}\nWHERE id IN ({{ids}})"),
                 "ids",
                 [1, 2],
                 :integer
               )

      assert body == "-- {{ids}}\nWHERE id IN ($1::integer, $2::integer)"
    end
  end

  describe "needs_preflight?/2 on tokens" do
    test "skips a statement that starts with SHOW, EXPLAIN or PRAGMA past comments" do
      pg = Postgres.wrap("pg", Repo)
      my = MySQL.wrap("my", MysqlRepo)
      lite = SQLite3.wrap("lite", SqliteRepo)

      refute Adapter.needs_preflight?(pg, Statement.new("SHOW search_path"))
      refute Adapter.needs_preflight?(pg, Statement.new("/* a /* b */ show */ SHOW search_path"))
      refute Adapter.needs_preflight?(my, Statement.new("# tables\nSHOW TABLES"))

      # EXPLAIN, and a SHOW that describes a table, are read for the tables
      # they describe.
      assert Adapter.needs_preflight?(pg, Statement.new("/* plan */ explain SELECT 1"))
      assert Adapter.needs_preflight?(pg, Statement.new("-- note\n  EXPLAIN SELECT 1"))
      assert Adapter.needs_preflight?(my, Statement.new("# cols\nSHOW COLUMNS FROM t"))
      assert Adapter.needs_preflight?(my, Statement.new("DESCRIBE t"))

      # SQLite reads the tables they name.
      assert Adapter.needs_preflight?(lite, Statement.new("PRAGMA table_info(t)"))
      assert Adapter.needs_preflight?(lite, Statement.new("EXPLAIN SELECT 1"))
    end

    test "runs the preflight when SHOW is the end of a nested comment" do
      pg = Postgres.wrap("pg", Repo)

      # PostgreSQL nests block comments, so SHOW is still inside the comment
      # and the statement is a SELECT.
      assert Adapter.needs_preflight?(
               pg,
               Statement.new("/* a /* b */ SHOW */ SELECT * FROM secrets")
             )
    end

    test "runs the preflight when the command is not a whole word" do
      pg = Postgres.wrap("pg", Repo)
      my = MySQL.wrap("my", MysqlRepo)

      assert Adapter.needs_preflight?(pg, Statement.new("SELECT * FROM shows"))
      assert Adapter.needs_preflight?(pg, Statement.new("SHOWS"))
      assert Adapter.needs_preflight?(pg, Statement.new("(SHOW x)"))
      assert Adapter.needs_preflight?(my, Statement.new("/*!50000 SHOW */ SELECT 1"))
      assert Adapter.needs_preflight?(pg, Statement.new("-- SHOW\nSELECT * FROM secrets"))
    end
  end

  describe "parse_alias_map/2 on tokens" do
    test "maps aliases to tables" do
      assert EctoAdapter.parse_alias_map(
               ~s|SELECT * FROM users u JOIN "Orders" AS o ON o.user_id = u.id|
             ) == %{"u" => "users", "o" => "Orders"}
    end

    test "ignores FROM and JOIN inside a string literal or a quoted identifier" do
      assert EctoAdapter.parse_alias_map(
               ~s|SELECT 'from secrets s' AS a, "join x y" FROM users u|
             ) == %{"u" => "users"}
    end

    test "reads past a comment marker inside a string literal" do
      assert EctoAdapter.parse_alias_map("SELECT '--' AS dash FROM users u") == %{
               "u" => "users"
             }
    end

    test "ignores FROM inside a comment and reads across one" do
      assert EctoAdapter.parse_alias_map("SELECT 1 /* FROM secrets s */ FROM users /* x */ u") ==
               %{"u" => "users"}
    end

    test "reads the dialect's quoted identifiers" do
      mysql = Profile.for_language("sql:mysql")

      assert EctoAdapter.parse_alias_map("SELECT * FROM `user table` AS `u`", mysql) == %{
               "u" => "user table"
             }

      # In MySQL a double-quoted run is a string, not a name.
      assert EctoAdapter.parse_alias_map(~s|SELECT "from a b" FROM users u|, mysql) == %{
               "u" => "users"
             }
    end
  end

  describe "strip_sql_comments/2 on tokens" do
    test "keeps comment markers inside string literals" do
      assert EctoAdapter.strip_sql_comments("SELECT '--x', '/*y*/' AS a -- note\nFROM t") ==
               "SELECT '--x', '/*y*/' AS a \nFROM t"
    end

    test "turns a block comment into a space" do
      assert EctoAdapter.strip_sql_comments("SELECT a/* c */FROM t") == "SELECT a FROM t"
    end

    test "nests block comments in PostgreSQL" do
      assert EctoAdapter.strip_sql_comments(
               "SELECT 1 /* a /* b */ c */ FROM t",
               Profile.for_language("sql:postgres")
             ) == "SELECT 1   FROM t"
    end
  end

  describe "MySQL table extraction on tokens" do
    alias Lotus.Source.Adapters.Ecto.Dialects.MySQL, as: MySQLDialect

    test "reads the table after a comment" do
      assert MySQLDialect.extract_tables_from_sql("SELECT * FROM /* c */ mysql.user") == [
               {"mysql", "user"}
             ]

      assert MySQLDialect.extract_tables_from_sql("SELECT * FROM -- c\n `mysql`.`db` d") == [
               {"mysql", "db"}
             ]
    end

    test "ignores FROM and JOIN inside strings, identifiers and comments" do
      assert MySQLDialect.extract_tables_from_sql(
               ~s|SELECT 'from a' AS x, "join b" AS y, `from c` FROM t # JOIN d\n|
             ) == [{nil, "t"}]
    end

    test "reads a backquoted name with any character" do
      assert MySQLDialect.extract_tables_from_sql("SELECT * FROM `my-db`.`my table`") == [
               {"my-db", "my table"}
             ]
    end

    test "reads every item of a FROM list and every join" do
      sql = """
      SELECT * FROM a x, b AS y, db.c, (SELECT 1 FROM d) e
      JOIN f ON 1 STRAIGHT_JOIN g NATURAL JOIN h CROSS JOIN i LEFT JOIN j USING (id)
      """

      assert Enum.sort(MySQLDialect.extract_tables_from_sql(sql)) ==
               Enum.sort([
                 {nil, "a"},
                 {nil, "b"},
                 {"db", "c"},
                 {nil, "d"},
                 {nil, "f"},
                 {nil, "g"},
                 {nil, "h"},
                 {nil, "i"},
                 {nil, "j"}
               ])

      assert MySQLDialect.extract_tables_from_sql("SELECT * FROM (a, b JOIN c ON 1) WHERE 1") ==
               [{nil, "a"}, {nil, "b"}, {nil, "c"}]

      assert MySQLDialect.extract_tables_from_sql(
               "SELECT * FROM a, LATERAL (SELECT 1 FROM b) AS l"
             ) == [{nil, "a"}, {nil, "b"}]
    end

    test "reads subqueries anywhere" do
      sql = """
      SELECT (SELECT max(id) FROM a) FROM b
      WHERE id IN (SELECT id FROM c) AND EXISTS (SELECT 1 FROM d, e WHERE 1)
      """

      assert Enum.sort(MySQLDialect.extract_tables_from_sql(sql)) ==
               [{nil, "a"}, {nil, "b"}, {nil, "c"}, {nil, "d"}, {nil, "e"}]
    end

    test "reads CTE bodies but not CTE names" do
      sql = """
      WITH RECURSIVE x AS (SELECT * FROM a), y (n) AS (SELECT 1 FROM b)
      SELECT * FROM x JOIN y ON 1, c
      """

      assert Enum.sort(MySQLDialect.extract_tables_from_sql(sql)) ==
               [{nil, "a"}, {nil, "b"}, {nil, "c"}]

      assert MySQLDialect.extract_tables_from_sql("SELECT a FROM t GROUP BY a WITH ROLLUP") ==
               [{nil, "t"}]
    end

    test "reads no table from a function's FROM, DUAL or a table function" do
      assert MySQLDialect.extract_tables_from_sql(
               "SELECT EXTRACT(YEAR FROM d), TRIM(LEADING 'x' FROM s) FROM DUAL"
             ) == []

      assert MySQLDialect.extract_tables_from_sql(
               "SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (a INT PATH '$')) AS jt"
             ) == []
    end

    @tag :mysql
    test "extract_accessed_resources names no alias, derived table or CTE as a table" do
      adapter = MySQL.wrap("my", MysqlRepo)

      for {sql, expected} <- [
            {"SELECT * FROM test_users u, test_posts p WHERE p.user_id = u.id",
             [{nil, "test_posts"}, {nil, "test_users"}]},
            {"SELECT * FROM (SELECT id FROM test_users LIMIT 3) d", [{nil, "test_users"}]},
            {"WITH x AS (SELECT id FROM test_users LIMIT 3) SELECT * FROM x, x AS y",
             [{nil, "test_users"}]},
            {"SELECT id FROM test_users UNION SELECT id FROM test_posts",
             [{nil, "test_posts"}, {nil, "test_users"}]},
            {"SELECT EXTRACT(YEAR FROM NOW()) FROM DUAL", []},
            {"SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (a INT PATH '$')) AS jt", []},
            {"SELECT * FROM mysql.db d", [{"mysql", "db"}]}
          ] do
        assert {:ok, relations} = Adapter.extract_accessed_resources(adapter, Statement.new(sql))
        assert Enum.sort(relations) == expected, sql
      end
    end

    @tag :mysql
    test "extract_accessed_resources sees a system table behind a comment" do
      adapter = MySQL.wrap("my", MysqlRepo)

      assert {:ok, relations} =
               Adapter.extract_accessed_resources(
                 adapter,
                 Statement.new("SELECT * FROM /* c */ mysql.user")
               )

      assert MapSet.member?(relations, {"mysql", "user"})
    end
  end
end
