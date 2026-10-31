defmodule Lotus.PreflightMysqlCaseTest do
  # MySQL reads its system schemas' names in any case.
  use Lotus.Case, async: false
  use Mimic

  @moduletag :mysql

  setup do
    stub(Lotus.Config, :visibility_for_source_name, fn _source -> %{} end)
    :ok
  end

  test "MySQL refuses a system schema in any case" do
    for sql <- [
          "SELECT table_name FROM INFORMATION_SCHEMA.COLUMNS",
          "SELECT table_name FROM Information_Schema.columns",
          "SHOW COLUMNS FROM INFORMATION_SCHEMA.COLUMNS"
        ] do
      assert {:error, "Query touches blocked table(s): information_schema." <> _} =
               Lotus.run_statement(sql, [], repo: "mysql"),
             sql
    end
  end
end
