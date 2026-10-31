defmodule Lotus.PreflightIntrospectionTest do
  # A statement that describes a table, or how a statement reads its tables,
  # is checked by what it describes.
  use Lotus.Case, async: false
  use Mimic

  setup do
    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{table: [deny: ["test_users"]]}
    end)

    :ok
  end

  defp run(sql, repo), do: Lotus.run_statement(sql, [], repo: repo)

  describe "PostgreSQL" do
    for sql <- [
          "EXPLAIN SELECT email FROM test_users",
          "/* plan */ EXPLAIN (FORMAT JSON, VERBOSE) SELECT email FROM test_users",
          "EXPLAIN VERBOSE SELECT email FROM test_users"
        ] do
      test "refuses on a hidden table: #{sql}" do
        assert {:error, "Query touches blocked table(s): public.test_users"} =
                 run(unquote(sql), "postgres")
      end
    end

    test "refuses EXPLAIN ANALYSE, as EXPLAIN ANALYZE" do
      for sql <- ["EXPLAIN (ANALYSE) SELECT 1", "EXPLAIN ANALYSE SELECT 1", "ANALYSE test_posts"] do
        assert {:error, "Only read-only queries are allowed" <> _} = run(sql, "postgres"), sql
      end
    end

    test "runs on visible tables, and SHOW as before" do
      assert {:ok, %{rows: [_ | _]}} = run("EXPLAIN SELECT title FROM test_posts", "postgres")
      assert {:ok, %{rows: [[_]]}} = run("SHOW search_path", "postgres")
    end
  end

  describe "MySQL" do
    @describetag :mysql

    for sql <- [
          "EXPLAIN test_users",
          "DESCRIBE `test_users`",
          "DESC test_users email",
          "EXPLAIN SELECT email FROM test_users",
          "EXPLAIN FORMAT=JSON SELECT email FROM test_users",
          "SHOW COLUMNS FROM test_users",
          "SHOW FULL FIELDS IN test_users",
          "SHOW INDEX FROM test_users",
          "SHOW KEYS IN test_users"
        ] do
      test "refuses on a hidden table: #{sql}" do
        assert {:error, "Query touches blocked table(s): " <> table} = run(unquote(sql), "mysql")
        assert table =~ "test_users"
      end
    end

    test "names the database a SHOW reads the table from" do
      assert {:error, "Query touches blocked table(s): lotus_test.test_users"} =
               run("SHOW COLUMNS FROM test_users FROM lotus_test", "mysql")
    end

    test "refuses EXPLAIN FOR CONNECTION" do
      assert {:error, "Lotus can't tell which tables EXPLAIN FOR CONNECTION reads"} =
               run("EXPLAIN FOR CONNECTION 1", "mysql")
    end

    test "runs on visible tables, and other SHOW statements as before" do
      for sql <- [
            "DESCRIBE test_posts",
            "EXPLAIN SELECT title FROM test_posts",
            "SHOW COLUMNS FROM test_posts",
            "SHOW TABLES"
          ] do
        assert {:ok, %{rows: [_ | _]}} = run(sql, "mysql"), sql
      end
    end
  end
end
