defmodule Lotus.AI.Actions.ValidateStatementTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.ValidateStatement
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter

  describe "run/2" do
    test "returns valid: true when validation succeeds" do
      expect(Adapter, :validate_statement, fn _adapter, %Statement{body: "SELECT 1"}, _opts ->
        :ok
      end)

      assert {:ok, %{valid: true}} =
               ValidateStatement.run(%{sql: "SELECT 1", data_source: "postgres"}, %{})
    end

    test "returns valid: false with error when validation fails" do
      expect(Adapter, :validate_statement, fn _adapter, %Statement{}, _opts ->
        {:error, "SQL syntax error: unexpected token"}
      end)

      assert {:ok, %{valid: false, error: error}} =
               ValidateStatement.run(
                 %{sql: "This is not SQL", data_source: "postgres"},
                 %{}
               )

      assert error =~ "syntax error"
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and schema" do
      assert ValidateStatement.name() == "validate_statement"
      assert ValidateStatement.description() =~ "Validate"
      assert Keyword.has_key?(ValidateStatement.schema(), :sql)
      assert Keyword.has_key?(ValidateStatement.schema(), :data_source)
    end
  end
end
