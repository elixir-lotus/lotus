defmodule Lotus.SqliteTimeoutTest do
  # The caller's timeout bounds a run on SQLite, whose dialect checks a
  # connection out for the whole run.
  use Lotus.Case, async: false

  @moduletag :sqlite

  test "a statement stops at the caller's timeout" do
    sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"

    {elapsed_us, result} =
      :timer.tc(fn -> Lotus.run_statement(sql, [], repo: "sqlite", timeout: 1_000) end)

    assert {:error, _} = result
    assert div(elapsed_us, 1000) < 5_000
  end
end
