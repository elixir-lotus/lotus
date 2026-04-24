defmodule Lotus.Source.Adapters.Ecto.SQL.SortInjector do
  @moduledoc """
  Shared helpers for SQL-based sources to inject sort directives into queries.

  Wraps the original query in a CTE and appends an ORDER BY clause.
  This ensures sorting works even when the original query already contains
  ORDER BY, GROUP BY, or other trailing clauses.

  Each SQL source calls this with its own `quote_fn` for identifier quoting.

  ## Example

      quote_fn = fn id -> ~s("\#{id}") end
      Lotus.Source.Adapters.Ecto.SQL.SortInjector.apply("SELECT * FROM users ORDER BY id", [
        %Lotus.Query.Sort{column: "created_at", direction: :desc}
      ], quote_fn)
      #=> ~s(WITH _sorted AS (SELECT * FROM users ORDER BY id) SELECT * FROM _sorted ORDER BY "created_at" DESC)
  """

  alias Lotus.Query.Sort
  alias Lotus.Source.Adapters.Ecto.SQL.Identifier

  import Lotus.Source.Adapters.Ecto.SQL.Sanitizer, only: [strip_trailing_semicolon: 1]

  @doc """
  Wraps the given SQL in a CTE and appends ORDER BY for each sort directive.

  `quote_fn` is a 1-arity function that quotes an identifier for the target database.

  Returns the original SQL unchanged if sorts is empty.

  Raises `ArgumentError` if any sort column name contains invalid characters.
  """
  @spec apply(String.t(), [Sort.t()], (String.t() -> String.t())) :: String.t()
  def apply(sql, [], _quote_fn), do: sql

  def apply(sql, sorts, quote_fn) when is_list(sorts) and is_function(quote_fn, 1) do
    order_clause = Enum.map_join(sorts, ", ", &build_sort_clause(&1, quote_fn))
    bare = strip_trailing_semicolon(sql)
    "WITH _sorted AS (#{bare}) SELECT * FROM _sorted ORDER BY #{order_clause}"
  end

  defp build_sort_clause(%Sort{column: column, direction: direction}, quote_fn) do
    Identifier.validate_identifier!(column, "sort column")
    "#{quote_fn.(column)} #{direction_to_sql(direction)}"
  end

  defp direction_to_sql(:asc), do: "ASC"
  defp direction_to_sql(:desc), do: "DESC"
end
