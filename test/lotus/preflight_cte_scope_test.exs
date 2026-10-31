defmodule Lotus.PreflightCteScopeTest do
  # A name is a CTE only where SQL puts the CTE in scope; anywhere else it
  # is the table of that name, and the visibility rules apply to it.
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Preflight.Columns
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Source.Adapters.Ecto.Dialects.MySQL.Relations

  @shadowed [
    "WITH a AS (SELECT name FROM secret), secret AS (SELECT 1 AS x) SELECT * FROM a",
    "SELECT name FROM secret WHERE EXISTS (WITH secret AS (SELECT 1 AS x) SELECT 1 FROM secret)",
    "SELECT * FROM (WITH secret AS (SELECT 1 AS x) SELECT * FROM secret) s, secret",
    "WITH secret AS (SELECT name FROM secret) SELECT * FROM secret"
  ]

  @in_scope [
    "WITH secret AS (SELECT 1 AS x) SELECT * FROM secret",
    "WITH a AS (SELECT 1 AS x), secret AS (SELECT * FROM a) SELECT * FROM secret",
    "WITH secret AS (SELECT 1 AS x) SELECT * FROM (SELECT * FROM secret) s",
    "WITH RECURSIVE secret AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM secret WHERE n < 3) SELECT * FROM secret"
  ]

  describe "the readers" do
    test "read a name outside its CTE's scope as a table" do
      for sql <- @shadowed do
        assert ["secret"] in Columns.table_names(sql, Profile.for_language("sql:postgres")), sql
        assert {nil, "secret"} in Relations.read(sql).tables, sql
      end
    end

    test "read a name in its CTE's scope as the CTE" do
      for sql <- @in_scope do
        refute ["secret"] in Columns.table_names(sql, Profile.for_language("sql:postgres")), sql
        refute {nil, "secret"} in Relations.read(sql).tables, sql
      end
    end
  end

  describe "preflight" do
    setup do
      stub(Lotus.Config, :visibility_for_source_name, fn _source ->
        %{table: [deny: ["test_users"]]}
      end)

      :ok
    end

    test "PostgreSQL refuses a hidden table a later CTE names, though the plan leaves it out" do
      assert {:error, "Query touches blocked table(s): public.test_users"} =
               Lotus.run_statement(
                 "WITH a AS (SELECT name FROM test_users WHERE false), test_users AS (SELECT 1) " <>
                   "SELECT * FROM a",
                 [],
                 repo: "postgres"
               )

      assert {:ok, _} =
               Lotus.run_statement(
                 "WITH test_users AS (SELECT 1 AS x) SELECT * FROM test_users",
                 [],
                 repo: "postgres"
               )
    end

    @tag :mysql
    test "MySQL refuses a hidden table a CTE elsewhere names" do
      for sql <- [
            "WITH a AS (SELECT name FROM test_users), test_users AS (SELECT 1 AS x) SELECT * FROM a",
            "SELECT name FROM test_users WHERE EXISTS " <>
              "(WITH test_users AS (SELECT 1 AS x) SELECT 1 FROM test_users)"
          ] do
        assert {:error, "Query touches blocked table(s): test_users"} =
                 Lotus.run_statement(sql, [], repo: "mysql"),
               sql
      end

      assert {:ok, _} =
               Lotus.run_statement(
                 "WITH test_users AS (SELECT 1 AS x) SELECT * FROM test_users",
                 [],
                 repo: "mysql"
               )
    end
  end
end
