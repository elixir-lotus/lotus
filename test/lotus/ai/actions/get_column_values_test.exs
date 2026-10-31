defmodule Lotus.AI.Actions.GetColumnValuesTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.GetColumnValues

  defmodule CoreOnlySource do
    @moduledoc false
    @behaviour Lotus.Source.Adapter

    @impl true
    def execute_query(_state, _body, _params, _opts),
      do: {:ok, %{columns: [], rows: [], num_rows: 0}}

    @impl true
    def transaction(state, fun, _opts), do: {:ok, fun.(state)}
    @impl true
    def list_tables(_state, _schemas, _opts), do: {:ok, []}
    @impl true
    def describe_table(_state, _schema, _table), do: {:ok, []}
    @impl true
    def builtin_denies(_state), do: []
    @impl true
    def health_check(_state), do: :ok
    @impl true
    def disconnect(_state), do: :ok
    @impl true
    def format_error(_state, error), do: inspect(error)
    @impl true
    def source_type(_state), do: :other
  end

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

    test "refuses a source that doesn't check its identifiers" do
      stub(Lotus.Source, :resolve!, fn _source, _fallback ->
        %Lotus.Source.Adapter{
          name: "core",
          module: CoreOnlySource,
          state: nil,
          source_type: :other
        }
      end)

      reject(&Lotus.run_statement/3)

      assert {:error, "This data source can't list a column's values"} =
               GetColumnValues.run(
                 %{data_source: "core", table_name: ~s(t" WHERE 1=1 --), column_name: "x"},
                 %{}
               )
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
