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
               ValidateStatement.run(%{statement: "SELECT 1", data_source: "postgres"}, %{})
    end

    test "returns valid: false with error when validation fails" do
      expect(Adapter, :validate_statement, fn _adapter, %Statement{}, _opts ->
        {:error, "SQL syntax error: unexpected token"}
      end)

      assert {:ok, %{valid: false, error: error}} =
               ValidateStatement.run(
                 %{statement: "SELECT name FROM test_users", data_source: "postgres"},
                 %{}
               )

      assert error =~ "syntax error"
    end

    test "a statement that fails the checks execution runs fails without validating" do
      reject(&Adapter.validate_statement/3)

      assert {:ok, %{valid: false, error: "Only a single statement is allowed"}} =
               ValidateStatement.run(
                 %{statement: "SELECT 1; SELECT 2", data_source: "postgres"},
                 %{}
               )
    end

    test "a table hidden from the actor's scope fails as execution would" do
      reject(&Adapter.validate_statement/3)

      stub(Lotus.Visibility, :allowed_relation?, fn
        _matcher, {_schema, "test_users"} -> false
        _matcher, _relation -> true
      end)

      assert {:ok, %{valid: false, error: error}} =
               ValidateStatement.run(
                 %{
                   statement: "SELECT name FROM test_users [[WHERE name = {{name}}]]",
                   data_source: "postgres"
                 },
                 %{scope: %{role: :viewer}}
               )

      assert error =~ "blocked table"
    end

    test "a source hidden from the actor's scope fails" do
      reject(&Adapter.validate_statement/3)

      stub(Lotus.Visibility, :source_visible?, fn
        "postgres", %{role: :viewer} -> false
        _source, _scope -> true
      end)

      assert {:ok, %{valid: false, error: ~s(Data source "postgres" is not available)}} =
               ValidateStatement.run(
                 %{statement: "SELECT 1", data_source: "postgres"},
                 %{scope: %{role: :viewer}}
               )
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and schema" do
      assert ValidateStatement.name() == "validate_statement"
      assert ValidateStatement.description() =~ "Validate"
      assert Keyword.has_key?(ValidateStatement.schema(), :statement)
      assert Keyword.has_key?(ValidateStatement.schema(), :data_source)
    end
  end
end
