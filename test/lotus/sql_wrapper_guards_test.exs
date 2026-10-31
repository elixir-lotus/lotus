defmodule Lotus.SqlWrapperGuardsTest do
  # Lotus's own SQL around a statement holds whatever the statement ends with,
  # and takes only the values it expects.
  use Lotus.Case, async: true

  alias Lotus.Query.{Filter, Sort, Statement}

  test "a statement that doesn't stay inside a filter or a sort is refused" do
    sql = "SELECT name FROM test_users) SELECT * FROM _base WHERE $1 IS NOT NULL --"

    assert {:error, "Query has unbalanced parentheses or an unclosed comment"} =
             Lotus.run_statement(sql, [],
               repo: "postgres",
               filters: [Filter.new("name", :eq, "x")]
             )

    assert {:error, "Query has unbalanced parentheses or an unclosed comment"} =
             Lotus.run_statement(sql, [], repo: "postgres", sorts: [Sort.new("name", :asc)])
  end

  test "limit_query takes only a positive integer" do
    statement = Statement.new("SELECT 1")

    assert %Statement{body: body} = Lotus.Source.limit_query("postgres", statement, 5)
    assert body =~ "LIMIT 5"

    for limit <- [0, -1, "5; DROP TABLE x", 1.5] do
      assert_raise FunctionClauseError, fn ->
        Lotus.Source.limit_query("postgres", statement, limit)
      end
    end
  end

  test "a statement timeout that is not an integer falls back to the default" do
    assert {:ok, %{rows: [[1]]}} =
             Lotus.run_statement("SELECT 1", [],
               repo: "postgres",
               statement_timeout_ms: "0; SET x = 1"
             )
  end
end
