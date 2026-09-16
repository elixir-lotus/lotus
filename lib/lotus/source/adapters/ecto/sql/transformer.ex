defmodule Lotus.Source.Adapters.Ecto.SQL.Transformer do
  @moduledoc """
  Shared SQL transformation utilities used by dialect implementations.

  Dialect modules call these helpers from their `transform_statement/1`
  callback to normalize SQL before variables are bound.

  Every transform tokenizes with `Lotus.Query.Tokenizer` under the dialect's
  `Lotus.Query.Tokenizer.Profile` and only rewrites string literals and code,
  so a pattern inside a comment, a quoted identifier or a dollar-quoted body
  is left alone. The profile defaults to ANSI SQL.
  """

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile

  @variable_name ~r/\A\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}\z/
  @interval_units ~w(DAY HOUR MINUTE SECOND WEEK MONTH YEAR)

  @doc """
  Strip quote wrappers from simple variable placeholders.

  Converts `'{{email}}'` → `{{email}}` but leaves complex expressions
  like `'%{{q}}%'` unchanged (those are handled by wildcard transforms).
  Any string quote of the profile counts, so MySQL's `"{{email}}"` is
  unwrapped too, while a double-quoted identifier on Postgres is not.
  """
  @spec strip_quoted_variables(String.t(), Profile.t()) :: String.t()
  def strip_quoted_variables(sql, %Profile{} = profile \\ Profile.for_language("sql")) do
    sql
    |> Tokenizer.tokenize(profile)
    |> map_strings(profile, fn content, _quote ->
      case Regex.run(@variable_name, content) do
        [_match, var] -> {:code, "{{" <> var <> "}}"}
        nil -> :keep
      end
    end)
    |> Tokenizer.to_string()
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
  @spec transform_wildcards(String.t(), :pipe | :concat_fn, Profile.t()) :: String.t()
  def transform_wildcards(
        sql,
        operator \\ :pipe,
        %Profile{} = profile \\ Profile.for_language("sql")
      ) do
    sql
    |> Tokenizer.tokenize(profile)
    |> map_strings(profile, fn content, _quote ->
      case wildcard_var(content) do
        {:both, var} -> {:code, build_concat(operator, ["'%'", "{{#{var}}}", "'%'"])}
        {:left, var} -> {:code, build_concat(operator, ["'%'", "{{#{var}}}"])}
        {:right, var} -> {:code, build_concat(operator, ["{{#{var}}}", "'%'"])}
        :no -> :keep
      end
    end)
    |> Tokenizer.to_string()
  end

  @doc """
  Transform PostgreSQL INTERVAL syntax with variable placeholders.

  Handles patterns like:
    * `INTERVAL {{var}}` → `({{var}}::text)::interval`
    * `INTERVAL '{{var}}'` → `CAST({{var}} AS interval)`
    * `INTERVAL '{{n}} days'` → `make_interval(days => ({{n}})::integer)`

  The keyword is matched without regard to case.
  """
  @spec transform_pg_intervals(String.t(), Profile.t()) :: String.t()
  def transform_pg_intervals(sql, %Profile{} = profile \\ Profile.for_language("sql")) do
    if String.contains?(sql, "{{") and Regex.match?(~r/interval/i, sql) do
      sql
      |> Tokenizer.tokenize(profile)
      |> rewrite_intervals([])
      |> Tokenizer.to_string()
    else
      sql
    end
  end

  defp rewrite_intervals([], acc), do: Enum.reverse(acc)

  defp rewrite_intervals([{:code, code} = token, next | rest], acc) do
    with {:ok, head, spacing} <- split_interval_keyword(code),
         {:ok, replacement, rest} <- interval_rewrite(next, spacing, rest) do
      rewrite_intervals(rest, [{:code, replacement}, {:code, head} | acc])
    else
      _ -> rewrite_intervals([next | rest], [token | acc])
    end
  end

  defp rewrite_intervals([{:block, inner} | rest], acc) do
    rewrite_intervals(rest, [{:block, rewrite_intervals(inner, [])} | acc])
  end

  defp rewrite_intervals([token | rest], acc), do: rewrite_intervals(rest, [token | acc])

  defp split_interval_keyword(code) do
    case Regex.run(~r/\A(.*?)\bINTERVAL(\s*)\z/is, code) do
      [_match, head, spacing] -> {:ok, head, spacing}
      nil -> :error
    end
  end

  defp interval_rewrite({:variable, var, _raw}, spacing, rest) when spacing != "" do
    if unit_follows?(rest) do
      :error
    else
      {:ok, "({{#{var}}}::text)::interval", rest}
    end
  end

  defp interval_rewrite({:string, <<"'", _::binary>> = raw}, _spacing, rest) do
    content = String.slice(raw, 1..-2//1)

    cond do
      match = Regex.run(~r/\A\s*\{\{\s*(\w+)\s*\}\}\s+\{\{\s*(\w+)\s*\}\}\s*\z/, content) ->
        [_, num_var, unit_var] = match
        {:ok, "((CAST({{#{num_var}}} AS text) || ' ' || {{#{unit_var}}})::interval)", rest}

      match = Regex.run(~r/\A\s*\{\{\s*(\w+)\s*\}\}\s*\z/, content) ->
        [_, var] = match
        {:ok, "CAST({{#{var}}} AS interval)", rest}

      match = Regex.run(~r/\A\s*([0-9]+)\s+\{\{\s*(\w+)\s*\}\}\s*\z/, content) ->
        [_, num, unit_var] = match
        {:ok, "(( '#{num} ' || {{#{unit_var}}} )::interval)", rest}

      match =
          Regex.run(~r/\A\{\{(\w+)\}\}\s+(day|hour|minute|second|week|month|year)s?\z/i, content) ->
        [_, var, unit] = match
        {:ok, "make_interval(#{ensure_plural(unit)} => ({{#{var}}})::integer)", rest}

      true ->
        :error
    end
  end

  defp interval_rewrite(_token, _spacing, _rest), do: :error

  defp unit_follows?([{:code, code} | _]) do
    Regex.match?(~r/\A\s+(#{Enum.join(@interval_units, "|")})\b/i, code)
  end

  defp unit_follows?(_rest), do: false

  defp ensure_plural(unit) do
    unit = String.downcase(unit)
    if String.ends_with?(unit, "s"), do: unit, else: unit <> "s"
  end

  # Applies `fun` to the content of every string literal delimited by one of
  # the profile's string quotes. `fun` returns `{:code, text}` to replace the
  # literal or `:keep` to leave it.
  defp map_strings(tokens, profile, fun) do
    Enum.map(tokens, fn
      {:string, raw} = token ->
        case string_content(raw, profile) do
          {:ok, content, quote} ->
            case fun.(content, quote) do
              {:code, text} -> {:code, text}
              :keep -> token
            end

          :error ->
            token
        end

      {:block, inner} ->
        {:block, map_strings(inner, profile, fun)}

      token ->
        token
    end)
  end

  defp string_content(raw, %Profile{string_quotes: quotes}) do
    Enum.find_value(quotes, :error, fn quote ->
      size = byte_size(quote)

      if byte_size(raw) >= 2 * size and String.starts_with?(raw, quote) and
           String.ends_with?(raw, quote) do
        {:ok, binary_part(raw, size, byte_size(raw) - 2 * size), quote}
      end
    end)
  end

  defp wildcard_var(content) do
    cond do
      match = Regex.run(~r/\A%\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}%\z/, content) ->
        {:both, Enum.at(match, 1)}

      match = Regex.run(~r/\A%\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}\z/, content) ->
        {:left, Enum.at(match, 1)}

      match = Regex.run(~r/\A\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}%\z/, content) ->
        {:right, Enum.at(match, 1)}

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
