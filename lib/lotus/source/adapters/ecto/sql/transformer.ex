defmodule Lotus.Source.Adapters.Ecto.SQL.Transformer do
  @moduledoc """
  Shared SQL transformation utilities used by dialect implementations.

  Dialect modules call these helpers from their `transform_statement/1`
  callback to normalize SQL before variables are bound.
  """

  @doc """
  Strip single-quoted wrappers from simple variable placeholders.

  Converts `'{{email}}'` → `{{email}}` but leaves complex expressions
  like `'%{{q}}%'` unchanged (those are handled by wildcard transforms).
  """
  @spec strip_quoted_variables(String.t()) :: String.t()
  def strip_quoted_variables(sql) do
    String.replace(sql, ~r/'([^']*)'/, fn full_match ->
      content = String.slice(full_match, 1..-2//1)

      if Regex.match?(~r/^\{\{[A-Za-z_][A-Za-z0-9_]*\}\}$/, content) do
        content
      else
        full_match
      end
    end)
  end

  @doc """
  Transform quoted wildcard patterns around variable placeholders into
  concatenation expressions using the given operator.

  ## Operators

    * `:pipe` — uses `||` (Postgres, SQLite, default SQL)
    * `:concat_fn` — uses `CONCAT()` (MySQL)

  ## Examples

      transform_wildcards("'%{{q}}%'", :pipe)
      # => "'%' || {{q}} || '%'"

      transform_wildcards("'%{{q}}%'", :concat_fn)
      # => "CONCAT('%', {{q}}, '%')"
  """
  @spec transform_wildcards(String.t(), :pipe | :concat_fn) :: String.t()
  def transform_wildcards(sql, operator \\ :pipe) do
    Regex.replace(~r/'([^']*)'/, sql, fn full ->
      content = String.slice(full, 1..-2//1)

      case wildcard_var(content) do
        {:both, var} -> build_concat(operator, ["'%'", "{{#{var}}}", "'%'"])
        {:left, var} -> build_concat(operator, ["'%'", "{{#{var}}}"])
        {:right, var} -> build_concat(operator, ["{{#{var}}}", "'%'"])
        :no -> full
      end
    end)
  end

  @doc """
  Transform PostgreSQL INTERVAL syntax with variable placeholders.

  Handles patterns like:
    * `INTERVAL {{var}}` → `({{var}}::text)::interval`
    * `INTERVAL '{{var}}'` → `CAST({{var}} AS interval)`
    * `INTERVAL '{{n}} days'` → `make_interval(days => ({{n}})::integer)`
  """
  @spec transform_pg_intervals(String.t()) :: String.t()
  def transform_pg_intervals(sql) do
    if String.contains?(sql, "INTERVAL") and String.contains?(sql, "{{") do
      do_transform_pg_intervals(sql)
    else
      sql
    end
  end

  defp do_transform_pg_intervals(sql) do
    sql
    |> then(fn s ->
      Regex.replace(
        ~r/INTERVAL\s+\{\{\s*(\w+)\s*\}\}(?!\s+(DAY|HOUR|MINUTE|SECOND|WEEK|MONTH|YEAR)\b)/i,
        s,
        fn _, var -> "({{#{var}}}::text)::interval" end
      )
    end)
    |> then(fn s ->
      Regex.replace(
        ~r/INTERVAL\s*'\s*\{\{\s*(\w+)\s*\}\}\s+\{\{\s*(\w+)\s*\}\}\s*'/i,
        s,
        fn _, num_var, unit_var ->
          "((CAST({{#{num_var}}} AS text) || ' ' || {{#{unit_var}}})::interval)"
        end
      )
    end)
    |> then(fn s ->
      Regex.replace(
        ~r/INTERVAL\s*'\s*\{\{\s*(\w+)\s*\}\}\s*'/i,
        s,
        fn _, var -> "CAST({{#{var}}} AS interval)" end
      )
    end)
    |> then(fn s ->
      Regex.replace(
        ~r/INTERVAL\s*'\s*([0-9]+)\s+\{\{\s*(\w+)\s*\}\}\s*'/i,
        s,
        fn _, num, unit_var -> "(( '#{num} ' || {{#{unit_var}}} )::interval)" end
      )
    end)
    |> then(fn s ->
      Regex.replace(
        ~r/INTERVAL\s+'\{\{(\w+)\}\}\s+(day|hour|minute|second|week|month|year)s?'/i,
        s,
        fn _, var, unit ->
          plural_unit = ensure_plural(unit)
          "make_interval(#{plural_unit} => ({{#{var}}})::integer)"
        end
      )
    end)
  end

  defp ensure_plural("day"), do: "days"
  defp ensure_plural("hour"), do: "hours"
  defp ensure_plural("minute"), do: "minutes"
  defp ensure_plural("second"), do: "seconds"
  defp ensure_plural("week"), do: "weeks"
  defp ensure_plural("month"), do: "months"
  defp ensure_plural("year"), do: "years"

  defp ensure_plural(unit) when is_binary(unit) do
    unit = String.downcase(unit)
    if String.ends_with?(unit, "s"), do: unit, else: unit <> "s"
  end

  defp wildcard_var(content) do
    cond do
      Regex.match?(~r/^%\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}%$/, content) ->
        [_, var] = Regex.run(~r/^%\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}%$/, content)
        {:both, var}

      Regex.match?(~r/^%\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}$/, content) ->
        [_, var] = Regex.run(~r/^%\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}$/, content)
        {:left, var}

      Regex.match?(~r/^\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}%$/, content) ->
        [_, var] = Regex.run(~r/^\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}%$/, content)
        {:right, var}

      true ->
        :no
    end
  end

  defp build_concat(:concat_fn, parts) do
    "CONCAT(" <> Enum.join(parts, ", ") <> ")"
  end

  defp build_concat(:pipe, parts) do
    Enum.join(parts, " || ")
  end
end
