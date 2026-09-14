defmodule Lotus.AI.Actions.GetColumnValuesTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.GetColumnValues

  describe "run/2" do
    test "returns distinct values for a column" do
      stub(Lotus, :run_statement, fn _query, _params, _opts ->
        {:ok, %{rows: [["active"], ["inactive"], ["pending"]]}}
      end)

      assert {:ok, result} =
               GetColumnValues.run(
                 %{data_source: "postgres", table_name: "public.users", column_name: "status"},
                 %{}
               )

      assert result.table == "public.users"
      assert result.column == "status"
      assert result.values == ["active", "inactive", "pending"]
      assert result.count == 3
    end

    test "returns empty values when column has no non-null values" do
      stub(Lotus, :run_statement, fn _query, _params, _opts ->
        {:ok, %{rows: []}}
      end)

      assert {:ok, result} =
               GetColumnValues.run(
                 %{data_source: "postgres", table_name: "users", column_name: "deleted_at"},
                 %{}
               )

      assert result.values == []
      assert result.count == 0
    end

    test "handles schema-qualified table names in SQL" do
      expect(Lotus, :run_statement, fn query, _params, _opts ->
        assert query =~ ~s("reporting"."invoices")
        {:ok, %{rows: [["open"], ["paid"]]}}
      end)

      assert {:ok, result} =
               GetColumnValues.run(
                 %{
                   data_source: "postgres",
                   table_name: "reporting.invoices",
                   column_name: "status"
                 },
                 %{}
               )

      assert result.values == ["open", "paid"]
    end

    test "rejects invalid column names" do
      assert {:error, msg} =
               GetColumnValues.run(
                 %{
                   data_source: "postgres",
                   table_name: "users",
                   column_name: "status; DROP TABLE users--"
                 },
                 %{}
               )

      assert msg =~ "Invalid column name"
    end

    test "rejects invalid table names" do
      assert {:error, msg} =
               GetColumnValues.run(
                 %{
                   data_source: "postgres",
                   table_name: "users\"",
                   column_name: "status"
                 },
                 %{}
               )

      assert msg =~ "Invalid table name"
    end

    test "returns error when query fails" do
      stub(Lotus, :run_statement, fn _query, _params, _opts ->
        {:error, "Permission denied"}
      end)

      assert {:error, "Permission denied"} =
               GetColumnValues.run(
                 %{data_source: "postgres", table_name: "users", column_name: "status"},
                 %{}
               )
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and schema" do
      assert GetColumnValues.name() == "get_column_values"
      assert GetColumnValues.description() =~ "distinct values"
      assert Keyword.has_key?(GetColumnValues.schema(), :table_name)
      assert Keyword.has_key?(GetColumnValues.schema(), :column_name)
    end
  end
end
