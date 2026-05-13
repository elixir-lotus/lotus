defmodule Lotus.AI.Actions.ValidateSQL do
  @moduledoc """
  Validates SQL syntax against the database without executing.

  Uses EXPLAIN to parse the query server-side, catching syntax errors
  and missing table/column references before the query is run.
  """

  @behaviour Lotus.AI.Action

  alias Lotus.Query.Statement
  alias Lotus.Source
  alias Lotus.Source.Adapter

  @impl true
  def name, do: "validate_sql"

  @impl true
  def description,
    do:
      "Validate a query statement against the data source without executing it. " <>
        "Use this to check your query for syntax errors before returning it. " <>
        "Variables ({{var}}) and optional clauses ([[...]]) are handled automatically."

  @impl true
  def schema do
    [
      sql: [type: :string, required: true, doc: "The query statement to validate"],
      data_source: [
        type: :string,
        required: true,
        doc: "Name of the data source to validate against"
      ]
    ]
  end

  @impl true
  def run(params, _context) do
    adapter = Source.resolve!(params.data_source, nil)
    statement = Statement.new(params.sql)

    case Adapter.validate_statement(adapter, statement, []) do
      :ok ->
        {:ok, %{valid: true}}

      {:error, reason} ->
        {:ok, %{valid: false, error: reason}}
    end
  end
end
