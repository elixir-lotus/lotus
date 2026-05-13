defmodule Lotus.Source.Adapters.EctoTest do
  use Lotus.Case, async: true

  alias Lotus.Query.Filter
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.Repo

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
      assert {"pg_catalog", ~r/.*/} in denies
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
  end

  describe "sanitize_query/3" do
    test "allows a single SELECT statement" do
      adapter = EctoAdapter.wrap("main", Repo)
      assert :ok = Adapter.sanitize_query(adapter, Statement.new("SELECT 1"), [])
    end

    test "rejects multiple statements" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:error, "Only a single statement is allowed"} =
               Adapter.sanitize_query(adapter, Statement.new("SELECT 1; DROP TABLE users"), [])
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
      assert %Statement{text: text} = out
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

      assert paged.text =~ "LIMIT"
      assert paged.text =~ "OFFSET"
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

    test "handled_errors/0 returns list of exception modules" do
      adapter = EctoAdapter.wrap("main", Repo)
      errors = Adapter.handled_errors(adapter)
      assert is_list(errors)
      assert Postgrex.Error in errors
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
  end

  describe "prepare_for_analysis/2" do
    test "neutralizes {{var}} placeholders to NULL" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, %Statement{text: prepared}} =
               Adapter.prepare_for_analysis(
                 adapter,
                 Statement.new("SELECT * FROM test_users WHERE id = {{id}}")
               )

      assert prepared =~ "id = NULL"
      refute prepared =~ "{{id}}"
    end

    test "strips [[...]] brackets while keeping inner content visible to the planner" do
      adapter = EctoAdapter.wrap("main", Repo)

      assert {:ok, %Statement{text: prepared}} =
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

    test "returns the prepared statement validatable by query_plan/4" do
      adapter = EctoAdapter.wrap("main", Repo)

      {:ok, prepared} =
        Adapter.prepare_for_analysis(
          adapter,
          Statement.new("SELECT id FROM test_users WHERE id = {{id}} [[AND name = {{name}}]]")
        )

      assert {:ok, _plan} = Adapter.query_plan(adapter, prepared.text, prepared.params, [])
    end
  end
end
