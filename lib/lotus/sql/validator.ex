defmodule Lotus.SQL.Validator do
  @moduledoc """
  Validates SQL syntax by preparing it against the database without executing.

  Uses EXPLAIN to parse the query server-side. Before validation, `{{var}}`
  placeholders are replaced with NULL and `[[...]]` optional brackets are
  stripped so the raw template can be checked.
  """

  alias Lotus.Config
  alias Lotus.Query.OptionalClause
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source
  alias Lotus.Source.Adapter
  alias Lotus.Variables

  @doc """
  Validates SQL syntax against the given data source.

  Neutralizes Lotus template syntax (`{{var}}` → `NULL`, `[[...]]` → inner
  content) and runs EXPLAIN to check whether the database can parse the
  statement.

  First it runs the checks a run makes (read-only mode, the source's
  visibility, the visibility rules and the column check), with `opts`:
  `:scope` and `:context` as a run takes them, and `:read_only`, by default
  the source's setting. A statement a run would refuse gets that refusal,
  before the database is asked about it.

  Returns `:ok` if the SQL is valid, or `{:error, reason}` with the
  refusal or the database error message if it is not.

  ## Examples

      iex> Lotus.SQL.Validator.validate("SELECT 1", "postgres")
      :ok

      iex> Lotus.SQL.Validator.validate("NOT VALID SQL", "postgres")
      {:error, "SQL syntax error: ..."}
  """
  @spec validate(String.t(), String.t() | module() | Adapter.t() | nil, keyword()) ::
          :ok | {:error, String.t()}
  def validate(sql, data_source, opts \\ []) do
    # Accept source names, repo modules, or already-resolved adapters via
    # Source.resolve!/2 — previous get_source!/1 only accepted name strings,
    # which meant callers with a repo module in hand had to round-trip it
    # through Source.name_from_module!/1 first.
    adapter = resolve_adapter(data_source)
    profile = Adapter.lexical_profile(adapter)

    neutralized =
      sql
      |> OptionalClause.strip_brackets(profile)
      |> Variables.neutralize("NULL", profile)

    statement = Statement.new(neutralized)
    read_only = Keyword.get_lazy(opts, :read_only, fn -> Config.read_only?(adapter) end)
    check_opts = [read_only: read_only] ++ Keyword.take(opts, [:scope, :context])

    with {:ok, _relations} <- Runner.check_statement(adapter, statement, check_opts),
         {:ok, _plan} <- Adapter.query_plan(adapter, statement, []) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_adapter(%Adapter{} = adapter), do: adapter
  defp resolve_adapter(source), do: Source.resolve!(source, nil)
end
