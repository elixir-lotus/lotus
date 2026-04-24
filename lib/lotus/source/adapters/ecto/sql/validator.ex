defmodule Lotus.Source.Adapters.Ecto.SQL.Validator do
  @moduledoc """
  Validates SQL syntax by preparing it against the database without executing.

  Uses EXPLAIN to parse the query server-side. Before validation, `{{var}}`
  placeholders are replaced with NULL and `[[...]]` optional brackets are
  stripped so the raw template can be checked.
  """

  alias Lotus.Query.OptionalClause
  alias Lotus.Source
  alias Lotus.Source.Adapter
  alias Lotus.Variables

  @doc """
  Validates SQL syntax against the given data source.

  Neutralizes Lotus template syntax (`{{var}}` → `NULL`, `[[...]]` → inner
  content) and runs EXPLAIN to check whether the database can parse the
  statement.

  Returns `:ok` if the SQL is valid, or `{:error, reason}` with the
  database error message if it is not.

  ## Examples

      iex> Lotus.Source.Adapters.Ecto.SQL.Validator.validate("SELECT 1", "postgres")
      :ok

      iex> Lotus.Source.Adapters.Ecto.SQL.Validator.validate("NOT VALID SQL", "postgres")
      {:error, "SQL syntax error: ..."}
  """
  @spec validate(String.t() | module() | Adapter.t(), String.t() | module() | nil) ::
          :ok | {:error, String.t()}
  def validate(sql, data_source) do
    neutralized =
      sql
      |> OptionalClause.strip_brackets()
      |> Variables.neutralize("NULL")

    # Accept source names, repo modules, or already-resolved adapters via
    # Source.resolve!/2 — previous get_source!/1 only accepted name strings,
    # which meant callers with a repo module in hand had to round-trip it
    # through Source.name_from_module!/1 first.
    adapter = resolve_adapter(data_source)

    case Adapter.query_plan(adapter, neutralized, [], []) do
      {:ok, _plan} -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp resolve_adapter(%Adapter{} = adapter), do: adapter
  defp resolve_adapter(source), do: Source.resolve!(source, nil)
end
