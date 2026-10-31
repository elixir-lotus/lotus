defmodule Lotus.AI.Actions.ValidateStatement do
  @moduledoc """
  Validates statement syntax against the data source without executing it.

  Runs the checks execution runs first, for the actor (sanitization, the
  source's visibility, preflight against the visibility rules, and how the
  statement uses protected columns), then the adapter's
  `validate_statement/3`, which parses the statement server-side and
  catches syntax errors and missing table or column references.
  """

  @behaviour Lotus.AI.Action

  alias Lotus.AI.Action
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source
  alias Lotus.Source.Adapter

  @impl true
  def name, do: "validate_statement"

  @impl true
  def description,
    do:
      "Validate a query statement against the data source without executing it. " <>
        "Use this to check your query for syntax errors before returning it. " <>
        "Variables ({{var}}) and optional clauses ([[...]]) are handled automatically."

  @impl true
  def schema do
    [
      statement: [type: :string, required: true, doc: "The query statement to validate"],
      data_source: [
        type: :string,
        required: true,
        doc: "Name of the data source to validate against"
      ]
    ]
  end

  @impl true
  def run(params, context) do
    adapter = Source.resolve!(params.data_source, nil)
    statement = Statement.new(params.statement)

    with :ok <- check(adapter, statement, Action.actor_opts(context)),
         :ok <- Adapter.validate_statement(adapter, statement, []) do
      {:ok, %{valid: true}}
    else
      {:error, reason} -> {:ok, %{valid: false, error: reason}}
    end
  end

  @doc false
  # The checks execution runs first, for the actor, on the statement with its
  # template syntax resolved: a statement that touches a hidden table fails
  # here as it would there, before the database can say whether it exists.
  # Every AI path that asks the database about a statement runs it.
  @spec check(Adapter.t(), Statement.t(), keyword()) :: :ok | {:error, String.t()}
  def check(adapter, statement, actor_opts) do
    analyzable =
      case Adapter.prepare_for_analysis(adapter, statement) do
        {:ok, prepared} -> prepared
        {:error, _reason} -> statement
      end

    case Runner.check_statement(adapter, analyzable, [read_only: true] ++ actor_opts) do
      {:ok, _relations} -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
