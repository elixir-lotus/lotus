defmodule Lotus.SQL.FilterInjector do
  @moduledoc ~S"""
  Shared helpers for SQL-based sources to inject filter conditions into queries.

  Wraps the original query in a CTE and appends WHERE clauses using parameterized
  queries. Each SQL source calls this with its own `quote_fn` and `placeholder_fn`
  for database-specific identifier quoting and parameter placeholders.

  ## Example

      quote_fn = fn id -> ~s("#{id}") end
      placeholder_fn = fn idx -> "$#{idx}" end
      Lotus.SQL.FilterInjector.apply("SELECT * FROM users", [25], [
        %Lotus.Query.Filter{column: "region", op: :eq, value: "US"}
      ], quote_fn, placeholder_fn)
      #=> {~s(WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE "region" = $2), [25, "US"]}
  """

  alias Lotus.Query.Filter
  alias Lotus.SQL.Identifier

  import Lotus.SQL.Sanitizer, only: [strip_trailing_semicolon: 1]

  @doc """
  Wraps the given SQL in a CTE and appends parameterized WHERE clauses for each filter.

  `quote_fn` is a 1-arity function that quotes an identifier for the target database.
  `placeholder_fn` is a 1-arity function that takes a 1-based parameter index and
  returns the placeholder string (e.g., `"$1"` for Postgres, `"?"` for MySQL).

  Returns `{sql, params}` where params is the updated parameter list with filter
  values appended. Returns `{sql, params}` unchanged if filters is empty.
  """
  @spec apply(String.t(), list(), [Filter.t()], (String.t() -> String.t()), (pos_integer() ->
                                                                               String.t())) ::
          {String.t(), list()}
  def apply(sql, params, [], _quote_fn, _placeholder_fn), do: {sql, params}

  def apply(sql, params, filters, quote_fn, placeholder_fn)
      when is_list(filters) and is_function(quote_fn, 1) and is_function(placeholder_fn, 1) do
    base_index = length(params)

    {condition_fragments, new_params} =
      build_conditions(filters, quote_fn, placeholder_fn, base_index, [], [])

    conditions = Enum.join(condition_fragments, " AND ")
    bare = strip_trailing_semicolon(sql)
    new_sql = "WITH _base AS (#{bare}) SELECT * FROM _base WHERE #{conditions}"

    {new_sql, params ++ new_params}
  end

  defp build_conditions([], _quote_fn, _placeholder_fn, _idx, frags, params) do
    {Enum.reverse(frags), Enum.reverse(params)}
  end

  defp build_conditions([filter | rest], quote_fn, placeholder_fn, idx, frags, params) do
    {frag, new_params, next_idx} = build_condition(filter, quote_fn, placeholder_fn, idx)

    build_conditions(
      rest,
      quote_fn,
      placeholder_fn,
      next_idx,
      [frag | frags],
      new_params ++ params
    )
  end

  defp build_condition(%Filter{column: column, op: :is_null}, quote_fn, _placeholder_fn, idx) do
    validate_column!(column)
    {"#{quote_fn.(column)} IS NULL", [], idx}
  end

  defp build_condition(%Filter{column: column, op: :is_not_null}, quote_fn, _placeholder_fn, idx) do
    validate_column!(column)
    {"#{quote_fn.(column)} IS NOT NULL", [], idx}
  end

  defp build_condition(
         %Filter{column: column, op: op, value: nil},
         quote_fn,
         _placeholder_fn,
         idx
       ) do
    validate_column!(column)

    case op do
      :eq -> {"#{quote_fn.(column)} IS NULL", [], idx}
      :neq -> {"#{quote_fn.(column)} IS NOT NULL", [], idx}
      _ -> {"#{quote_fn.(column)} #{op_to_sql(op)} NULL", [], idx}
    end
  end

  defp build_condition(
         %Filter{column: column, op: op, value: value},
         quote_fn,
         placeholder_fn,
         idx
       ) do
    validate_column!(column)
    param_idx = idx + 1
    placeholder = placeholder_fn.(param_idx)
    {"#{quote_fn.(column)} #{op_to_sql(op)} #{placeholder}", [value], param_idx}
  end

  defp validate_column!(column) do
    Identifier.validate_identifier!(column, "filter column")
  end

  defp op_to_sql(:eq), do: "="
  defp op_to_sql(:neq), do: "!="
  defp op_to_sql(:gt), do: ">"
  defp op_to_sql(:lt), do: "<"
  defp op_to_sql(:gte), do: ">="
  defp op_to_sql(:lte), do: "<="
  defp op_to_sql(:like), do: "LIKE"
end
