defmodule Lotus.AI.Actions.DescribeTableTest do
  use Lotus.AICase, async: true

  import Lotus.AIFixtures

  alias Lotus.AI.Actions.DescribeTable

  describe "run/2" do
    test "returns column details for a table" do
      stub(Lotus.Schema, :describe_table, fn _source, _table ->
        {:ok, users_table_schema()}
      end)

      assert {:ok, result} =
               DescribeTable.run(%{data_source: "postgres", table_name: "users"}, %{})

      assert result.table == "users"
      assert length(result.columns) == 4

      [id_col | _] = result.columns
      assert id_col.name == "id"
      assert id_col.type == "integer"
      assert id_col.nullable == false
      assert id_col.primary_key == true
    end

    test "parses schema-qualified table names" do
      expect(Lotus.Schema, :describe_table, fn _source, table, opts ->
        assert table == "customers"
        assert opts[:schema] == "reporting"
        {:ok, [%{name: "id", type: "integer", nullable: false, primary_key: true}]}
      end)

      assert {:ok, result} =
               DescribeTable.run(
                 %{data_source: "postgres", table_name: "reporting.customers"},
                 %{}
               )

      assert result.table == "reporting.customers"
    end

    test "rejects invalid table names" do
      assert {:error, msg} =
               DescribeTable.run(
                 %{data_source: "postgres", table_name: "users\"; DROP TABLE users--"},
                 %{}
               )

      assert msg =~ "Invalid table name"
    end

    test "returns error when table not found" do
      stub(Lotus.Schema, :describe_table, fn _source, _table ->
        {:error, "Table not found"}
      end)

      assert {:error, "Table not found"} =
               DescribeTable.run(%{data_source: "postgres", table_name: "unknown"}, %{})
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and schema" do
      assert DescribeTable.name() == "describe_table"
      assert DescribeTable.description() =~ "column details"
      assert Keyword.has_key?(DescribeTable.schema(), :table_name)
      assert Keyword.has_key?(DescribeTable.schema(), :data_source)
    end
  end
end
