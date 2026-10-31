defmodule Lotus.Preflight.Columns do
  @moduledoc """
  Checks how a SQL statement uses the columns a column policy protects.

  Column policies (`:mask`, `:omit`, `:error`) apply to result columns by
  name, so they only hold while a protected column reaches the result under
  its own name. A statement that renames it (`ssn AS s`), wraps it in an
  expression (`upper(ssn)`, `ssn || ''`, `ssn::int`), or reads it anywhere
  else (`WHERE ssn = ...`, `ORDER BY ssn`, a subquery) would return or reveal
  the value under a name no policy matches. This check refuses those
  statements before they run.

  A protected column may appear only as a select item, as is (`SELECT ssn`,
  `SELECT u.ssn`, `SELECT ssn AS ssn`), of the statement itself or of a
  derived table or CTE it reads from (`SELECT * FROM (SELECT ssn FROM
  users) t`, the shape filters, sorts and pagination wrap a statement in). When a statement
  touches a relation with a protected column, it also may not:

    * refer to a whole row (`SELECT u`, `to_json(u)`, `row(u.*)`);
    * rename columns with a column alias list (`AS t(a, b)`,
      `WITH c(a, b) AS ...`);
    * join with `NATURAL`, which compares every column the two sides share
      by name, none of them written in the statement;
    * combine `*` or `TABLE t` with `UNION`, `INTERSECT` or `EXCEPT`, whose
      result takes the first branch's column names;
    * sort or group by the position of a protected column (`SELECT ssn ...
      ORDER BY 1`, also in `GROUP BY`, `DISTINCT ON`, `ROLLUP`, `CUBE` and
      `GROUPING SETS`), which reveals how its values order or repeat, or by a
      position it can't match to a select item (at or after a `*`).

  A column is protected by name, by the strictest policy any relation the
  statement touches has for it, unless the name is qualified (`o.ssn`,
  `orders.ssn`, `public.orders.ssn`) by a relation the check can tell for
  sure: an alias or table name bound exactly once in the statement's FROM
  and JOIN clauses, standing nowhere else, to a table preflight found (not a
  CTE, derived table or function). Such a name reads that table's column,
  protected only if a policy for that table is. `result_sources/4` hands the
  runner the same decision for each result column, so the policy it applies
  to a column is the one this check judged it by.

  The check reads tokens, not a parse tree, so it fails closed: whatever it
  can't prove keeps the name is refused. `SELECT *` and `SELECT t.*` pass,
  since the result keeps the column names. A name that is a whole `ORDER BY`
  item and an output column of its query (`count(*) AS users ... ORDER BY
  users`) sorts by that column, as the database reads it, not by a row. The
  alias of `generate_series` or `generate_subscripts` in FROM names a number
  or a time, never a row; any other function's alias is taken for one. A view or function that renames
  a protected column inside the database is beyond it; hide such columns
  from the role Lotus connects as.
  """

  alias Lotus.Preflight.Relations
  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Visibility
  alias Lotus.Visibility.Matcher

  # Only the words the check steers by. Any other word may be a column.
  @keywords ~w(select distinct all from as union intersect except minus where group having
               order limit offset fetch window qualify returning join on using with recursive
               lateral inner left right full outer cross natural only by into values table)

  # Words SQL is often written with in capitals.
  @common_words ~w(and or not null is in like ilike between case when then else end asc desc
                   nulls first last exists true false any some cast interval count sum avg min
                   max coalesce over partition rows range current row date timestamp now)

  @select_starts [{:kw, "select"}, {:kw, "distinct"}, {:kw, "all"}, ","]
  @item_ends [",", {:kw, "from"}, :eof]
  @clause_ends ~w(where having limit offset fetch window qualify returning)
  @set_ops ~w(union intersect except minus)
  @query_clauses [:select, :from, :join_cond, :order, :group, :other]

  # The clauses whose whole integer items name a select item.
  @position_clauses [:order, :group, :table_order]
  @table_starts [{:kw, "from"}, {:kw, "join"}, ",", {:kw, "lateral"}, {:kw, "only"}]

  # Functions in FROM whose rows are a number or a time, never a table's
  # row: their alias is no whole-row reference. Their arguments are checked
  # as anything else is.
  @scalar_functions ~w(generate_series generate_subscripts)

  # What may follow a whole ORDER BY item.
  @sort_item_ends [",", ")", ";", :eof, {:kw, "limit"}, {:kw, "offset"}, {:kw, "fetch"}]
  @sort_modifiers ~w(asc desc nulls)

  # What may precede a whole grouping or sort item in parentheses.
  @grouping_sets ~w(rollup cube sets)

  # How many qualifiers are looked up one by one before all are worked out.
  @max_scans 8

  # Punctuation the check steers by, kept as literals.
  @punctuation ~w|( ) , . * ; [ ]|

  @typedoc """
  Where a result column comes from: the relation whose column it is, when
  the select item is that column as is under a qualifier that names one
  relation for sure (see the moduledoc), or `:unresolved`.
  """
  @type source :: {:relation, Relations.relation()} | :unresolved

  @typedoc """
  The sources of a statement's result columns, by position. A column past
  the end of the list (one at or after a `*` or `t.*`) is `:unresolved`.
  `nil` when nothing is known: a set operation, a statement whose result
  isn't a plain select list, or one that renames columns with a column
  alias list.
  """
  @type sources :: [source()] | nil

  @doc """
  Checks `sql` against the column policies of `matcher` for the relations
  preflight found. Returns `:ok` or `{:error, message}`.
  """
  @spec check(String.t(), Profile.t(), Matcher.t(), Relations.outcome()) ::
          :ok | {:error, String.t()}
  def check(sql, %Profile{} = profile, %Matcher{} = matcher, relations) when is_binary(sql) do
    rels = Relations.to_list(relations)

    if Matcher.restricts_columns?(matcher, rels) do
      with {:ok, _sources} <- sql |> lex(profile) |> annotate() |> verify(matcher, rels),
           do: :ok
    else
      :ok
    end
  end

  def check(_sql, _profile, _matcher, _relations), do: :ok

  @doc """
  `check/4`, returning on success where each result column comes from (see
  `t:sources/0`), so that a column policy can apply by the column's own
  relation rather than by its name across every relation.

  A statement that only selects `*` from one derived table or CTE, and only
  filters, sorts or cuts its rows (the wrappers of a window, a filter and a
  sort), has the columns of the statement inside, in order, so it has that
  statement's sources. Anything else is judged as it stands.

  The sources are worked out whether or not `matcher` protects a column, so
  that a consumer with column rules of its own (an `:after_query` plug) can
  apply them by the same decision: a column traced to its relation gets that
  relation's rule, any other the strictest any touched relation has.
  """
  @spec result_sources(String.t(), Profile.t(), Matcher.t(), Relations.outcome()) ::
          {:ok, sources()} | {:error, String.t()}
  def result_sources(sql, %Profile{} = profile, %Matcher{} = matcher, relations)
      when is_binary(sql) do
    rels = Relations.to_list(relations)
    lexemes = lex(sql, profile)

    if Matcher.restricts_columns?(matcher, rels) do
      with {:ok, sources} <- lexemes |> annotate() |> verify(matcher, rels),
           do: {:ok, through_wrappers(lexemes, rels, sources)}
    else
      {:ok, unchecked_sources(lexemes, rels)}
    end
  end

  def result_sources(_sql, _profile, _matcher, _relations), do: {:ok, nil}

  # The sources of a statement no column policy restricts: nothing to refuse,
  # so a statement the check would refuse (a column alias list) and anything
  # it can't read have no sources, which a consumer takes for unknown.
  defp unchecked_sources(lexemes, rels) do
    case unwrap(lexemes) do
      {:inner, inner} -> unchecked_sources(inner, rels)
      :none -> own_sources(lexemes, rels)
    end
  rescue
    _ -> nil
  end

  # The check passed the whole statement. When it only selects `*` from one
  # derived table or CTE, its columns are that statement's, in order.
  defp through_wrappers(lexemes, rels, sources) do
    case unwrap(lexemes) do
      {:inner, inner} -> unchecked_sources(inner, rels)
      :none -> sources
    end
  end

  defp own_sources(lexemes, rels) do
    case annotate(lexemes) do
      %{alias_list?: true} ->
        nil

      notes ->
        column_sources(
          %{out: notes.out, ctes: notes.ctes, rels: rels, set_op?: notes.set_op?},
          %{}
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Wrappers: a statement whose columns are another's
  # ---------------------------------------------------------------------------

  # A window, a filter and a sort wrap the caller's statement, and its
  # columns pass through unchanged:
  #
  #     SELECT * FROM (inner) AS lotus_sub LIMIT $2 OFFSET $3
  #     WITH _base AS (inner) SELECT * FROM _base WHERE "region" = $2
  #     WITH _sorted AS (inner) SELECT * FROM _sorted ORDER BY "id" DESC
  #
  # Any statement of these shapes selects `*` from exactly one derived table
  # or CTE, so its columns are the inner statement's, in the same order, and
  # each has the inner statement's source. What follows the derived table or
  # CTE may only filter, sort or cut rows (WHERE, ORDER BY, LIMIT, OFFSET,
  # FETCH), with no set operation or join at its level. A column alias list
  # (`AS t(a, b)`), a second CTE, `RECURSIVE`, `MATERIALIZED` or anything else
  # is no wrapper: the statement's sources are its own, `:unresolved` through
  # its `*`.
  defp unwrap(lexemes) do
    case strip_semicolons(lexemes) do
      [{:kw, "select"}, "*", {:kw, "from"}, "(" | rest] ->
        with {:ok, inner, after_inner} <- closing(rest, 0, []),
             {:ok, tail} <- derived_alias(after_inner),
             true <- inner != [] and row_tail?(tail) do
          {:inner, inner}
        else
          _ -> :none
        end

      [{:kw, "with"}, {:name, _raw, name}, {:kw, "as"}, "(" | rest] ->
        with {:ok, inner, after_inner} <- closing(rest, 0, []),
             [{:kw, "select"}, "*", {:kw, "from"}, {:name, _, ^name} | tail] <- after_inner,
             true <- inner != [] and row_tail?(tail) do
          {:inner, inner}
        else
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp strip_semicolons(lexemes) do
    lexemes |> :lists.reverse() |> Enum.drop_while(&(&1 == ";")) |> :lists.reverse()
  end

  # The lexemes up to the `)` that closes the one before them, and those
  # after it.
  defp closing([")" | rest], 0, acc), do: {:ok, :lists.reverse(acc), rest}
  defp closing([")" | rest], depth, acc), do: closing(rest, depth - 1, [")" | acc])
  defp closing(["(" | rest], depth, acc), do: closing(rest, depth + 1, ["(" | acc])
  defp closing([lexeme | rest], depth, acc), do: closing(rest, depth, [lexeme | acc])
  defp closing([], _depth, _acc), do: :error

  defp derived_alias([{:kw, "as"}, {:name, _, _} | tail]), do: {:ok, tail}
  defp derived_alias([{:name, _, _} | tail]), do: {:ok, tail}
  defp derived_alias(_after_inner), do: :error

  @row_clauses ~w(where order limit offset fetch)
  @not_in_row_tail @set_ops ++ ~w(join select from with)

  # Nothing, or clauses that keep the columns, with no set operation, join
  # or other query at their level.
  defp row_tail?([]), do: true
  defp row_tail?([{:kw, kw} | _] = tail) when kw in @row_clauses, do: flat_tail?(tail, 0)
  defp row_tail?(_tail), do: false

  defp flat_tail?([], _depth), do: true
  defp flat_tail?(["(" | rest], depth), do: flat_tail?(rest, depth + 1)
  defp flat_tail?([")" | _rest], 0), do: false
  defp flat_tail?([")" | rest], depth), do: flat_tail?(rest, depth - 1)
  defp flat_tail?([";" | _rest], _depth), do: false
  defp flat_tail?([{:kw, kw} | _rest], 0) when kw in @not_in_row_tail, do: false
  defp flat_tail?([_lexeme | rest], depth), do: flat_tail?(rest, depth)

  @doc false
  # The tables a statement names in FROM and JOIN, as name paths
  # (`[schema, table]` or `[table]`), CTEs and functions left out. A dialect
  # whose plan can omit a table the planner proved empty (`WHERE false`)
  # resolves these to make sure preflight still sees it. A name is a CTE
  # only where SQL puts the CTE in scope (see `cte_scopes/2`); anywhere
  # else it is the table of that name.
  @spec table_names(String.t(), Profile.t()) :: [[String.t()]]
  def table_names(sql, %Profile{} = profile) when is_binary(sql) do
    %{out: out} = sql |> lex(profile) |> annotate()
    scopes = out |> Enum.map(&elem(&1, 0)) |> cte_scopes([])

    out |> table_paths(:bof, scopes, []) |> Enum.reverse() |> Enum.uniq()
  end

  defp table_paths([{lexeme, _reaches?, clause, _level} = entry | rest], prev, scopes, acc) do
    acc =
      with {:name, _raw, _down} <- lexeme,
           :from <- clause,
           true <- prev in @table_starts,
           {path, after_path} = path_of([entry | rest], []),
           true <- next_lexeme(after_path) != "(",
           false <- cte_in_scope?(path, scopes, length(rest) + 1) do
        [path | acc]
      else
        _ -> acc
      end

    table_paths(rest, lexeme, scopes, acc)
  end

  defp table_paths([], _prev, _scopes, acc), do: acc

  # The raw names of a `schema.table` path at the head of `entries`, and the
  # entries after it.
  defp path_of([{{:name, raw, _down}, _reaches?, _clause, _level} | rest], acc) do
    case rest do
      [{".", _, _, _} | [{{:name, _, _}, _, _, _} | _] = more] -> path_of(more, [raw | acc])
      _ -> {:lists.reverse([raw | acc]), rest}
    end
  end

  defp cte?([name], ctes), do: Map.has_key?(ctes, downcase(name))
  defp cte?(_path, _ctes), do: false

  defp cte_in_scope?([name], scopes, left) do
    down = downcase(name)
    Enum.any?(scopes, fn {cte, from, to} -> cte == down and to < left and left < from end)
  end

  defp cte_in_scope?(_path, _scopes, _left), do: false

  # Where each CTE is in scope, as `{name, from, to}`: a name with `n`
  # lexemes left, its own included, is the CTE when `to < n < from`. A CTE
  # is in scope after its definition in its WITH list (from its own name
  # on, with RECURSIVE), up to the parenthesis that closes the query the
  # WITH belongs to (`to`, 0 at the top).
  defp cte_scopes([], scopes), do: scopes

  defp cte_scopes([{:kw, "with"} | rest], scopes) do
    {recursive?, items} =
      case rest do
        [{:kw, "recursive"} | items] -> {true, items}
        _ -> {false, rest}
      end

    to = rest |> after_group() |> length() |> closing_left()
    cte_scopes(rest, scope_items(items, recursive?, to, scopes))
  end

  defp cte_scopes([_lexeme | rest], scopes), do: cte_scopes(rest, scopes)

  defp closing_left(0), do: 0
  defp closing_left(after_close), do: after_close + 1

  defp scope_items([{:name, _raw, down} | rest] = items, recursive?, to, scopes) do
    from_name = length(items)
    rest = if match?(["(" | _], rest), do: after_group(tl(rest)), else: rest

    with [{:kw, "as"} | rest] <- rest,
         rest = skip_materialized(rest),
         ["(" | body] <- rest do
      after_body = after_group(body)
      from = if recursive?, do: from_name, else: length(after_body) + 1
      scopes = [{down, from, to} | scopes]

      case after_body do
        ["," | more] -> scope_items(more, recursive?, to, scopes)
        _ -> scopes
      end
    else
      _ -> scopes
    end
  end

  defp scope_items(_lexemes, _recursive?, _to, scopes), do: scopes

  # `AS [NOT] MATERIALIZED (...)`.
  defp skip_materialized([{:name, _, "not"}, {:name, _, "materialized"} | rest]), do: rest
  defp skip_materialized([{:kw, "not"}, {:name, _, "materialized"} | rest]), do: rest
  defp skip_materialized([{:name, _, "materialized"} | rest]), do: rest
  defp skip_materialized(rest), do: rest

  # The lexemes after the `)` that closes an open parenthesis.
  defp after_group(lexemes), do: after_group(lexemes, 1)
  defp after_group([], _depth), do: []
  defp after_group([")" | rest], 1), do: rest
  defp after_group([")" | rest], depth), do: after_group(rest, depth - 1)
  defp after_group(["(" | rest], depth), do: after_group(rest, depth + 1)
  defp after_group([_lexeme | rest], depth), do: after_group(rest, depth)

  defp next_lexeme([{lexeme, _reaches?, _clause, _level} | _]), do: lexeme
  defp next_lexeme([]), do: :eof

  # ---------------------------------------------------------------------------
  # Lexing: code becomes words and punctuation; literals and comments drop out
  # ---------------------------------------------------------------------------

  # Lexemes are `{:kw, word}` for a keyword, `{:name, raw, lowercase}` for any
  # other word or a quoted identifier, `{:int, digits}` for an integer, `:lit`
  # for any other literal, `:escaped_name`, or the punctuation itself. A word
  # is what the databases take for an unquoted identifier: a letter or `_`,
  # then letters, digits, `_` or `$`, where any non-ASCII character counts as
  # a letter. The lexer matches bytes; it runs no regex.
  defp lex(sql, profile),
    do: sql |> Tokenizer.tokenize(profile) |> lex_tokens([]) |> :lists.reverse()

  # PostgreSQL's `U&"\0073sn"` spells a name with escapes this check doesn't
  # decode, so it stands for a name that can't be compared.
  defp lex_tokens([{:code, raw}, {:identifier, _} = identifier | rest], acc) do
    size = byte_size(raw)

    if size >= 2 and :binary.part(raw, size - 2, 2) in ["u&", "U&"],
      do: lex_tokens(rest, [:escaped_name | lex_code(:binary.part(raw, 0, size - 2), acc)]),
      else: lex_tokens([identifier | rest], lex_code(raw, acc))
  end

  defp lex_tokens([token | rest], acc), do: lex_tokens(rest, lex_token(token, acc))
  defp lex_tokens([], acc), do: acc

  defp lex_token({:code, raw}, acc), do: lex_code(raw, acc)

  defp lex_token({:identifier, raw}, acc) do
    name = unquote_identifier(raw)
    [{:name, name, downcase(name)} | acc]
  end

  defp lex_token({:string, _raw}, acc), do: [:lit | acc]
  defp lex_token({:variable, _name, _raw}, acc), do: [:lit | acc]
  defp lex_token({:block, inner}, acc), do: lex_tokens(inner, acc)
  defp lex_token({:comment, _raw}, acc), do: acc

  defp lex_code(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v],
    do: lex_code(rest, acc)

  defp lex_code(<<c, _::binary>> = code, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 128 do
    {size, upper?, ascii?} = word_size(code, 1, c in ?A..?Z, c < 128)
    <<word::binary-size(^size), rest::binary>> = code
    lex_code(rest, [word(word, upper?, ascii?) | acc])
  end

  defp lex_code(<<c, _::binary>> = code, acc) when c in ?0..?9 do
    {size, int?} = number_size(code, digits_size(code, 1))
    <<number::binary-size(^size), rest::binary>> = code
    lex_code(rest, [if(int?, do: {:int, number}, else: :lit) | acc])
  end

  defp lex_code(<<"::", rest::binary>>, acc), do: lex_code(rest, ["::" | acc])

  for p <- @punctuation do
    defp lex_code(<<unquote(p), rest::binary>>, acc), do: lex_code(rest, [unquote(p) | acc])
  end

  defp lex_code(<<c, rest::binary>>, acc), do: lex_code(rest, [<<c>> | acc])
  defp lex_code(<<>>, acc), do: acc

  # The size of the word at the head of `code`, whether it has an ASCII
  # capital, and whether it is all ASCII.
  defp word_size(code, n, upper?, ascii?) do
    case code do
      <<_::binary-size(^n), c, _::binary>> when c in ?a..?z or c in ?0..?9 or c in [?_, ?$] ->
        word_size(code, n + 1, upper?, ascii?)

      <<_::binary-size(^n), c, _::binary>> when c in ?A..?Z ->
        word_size(code, n + 1, true, ascii?)

      <<_::binary-size(^n), c, _::binary>> when c >= 128 ->
        word_size(code, n + 1, upper?, false)

      _ ->
        {n, upper?, ascii?}
    end
  end

  defp digits_size(code, n) do
    case code do
      <<_::binary-size(^n), c, _::binary>> when c in ?0..?9 -> digits_size(code, n + 1)
      _ -> n
    end
  end

  # Digits, then perhaps `.digits`, then perhaps an exponent: `1`, `1.5`,
  # `1e-3`. Only digits alone are an integer.
  defp number_size(code, n) do
    n2 =
      case code do
        <<_::binary-size(^n), ?., c, _::binary>> when c in ?0..?9 -> digits_size(code, n + 2)
        _ -> n
      end

    n3 =
      case code do
        <<_::binary-size(^n2), e, c, _::binary>> when e in [?e, ?E] and c in ?0..?9 ->
          digits_size(code, n2 + 2)

        <<_::binary-size(^n2), e, s, c, _::binary>>
        when e in [?e, ?E] and s in [?+, ?-] and c in ?0..?9 ->
          digits_size(code, n2 + 3)

        _ ->
          n2
      end

    {n3, n3 == n}
  end

  defp word(word, upper?, ascii?) do
    case known(word) do
      nil when ascii? and not upper? ->
        {:name, word, word}

      nil ->
        down = if ascii?, do: String.downcase(word, :ascii), else: String.downcase(word)
        keyword(down) || {:name, word, down}

      lexeme ->
        lexeme
    end
  end

  # A keyword in lower or upper case, or a common word in upper case, needs
  # no lowering.
  for keyword <- @keywords do
    defp known(unquote(keyword)), do: {:kw, unquote(keyword)}
    defp known(unquote(String.upcase(keyword))), do: {:kw, unquote(keyword)}
  end

  for word <- @common_words, upper = String.upcase(word) do
    defp known(unquote(upper)), do: {:name, unquote(upper), unquote(word)}
  end

  defp known(_word), do: nil

  for keyword <- @keywords do
    defp keyword(unquote(keyword)), do: {:kw, unquote(keyword)}
  end

  defp keyword(_word), do: nil

  defp downcase(name) do
    case case_of(name) do
      :lower -> name
      :ascii -> String.downcase(name, :ascii)
      :unicode -> String.downcase(name)
    end
  end

  defp case_of(<<c, _::binary>>) when c >= 128, do: :unicode
  defp case_of(<<c, rest::binary>>) when c in ?A..?Z, do: upper_case_of(rest)
  defp case_of(<<_, rest::binary>>), do: case_of(rest)
  defp case_of(<<>>), do: :lower

  defp upper_case_of(<<c, _::binary>>) when c >= 128, do: :unicode
  defp upper_case_of(<<_, rest::binary>>), do: upper_case_of(rest)
  defp upper_case_of(<<>>), do: :ascii

  # The quotes off, a doubled quote made one; SQLite's `[name]` has no
  # escapes. An unterminated identifier runs to the end of the input; its
  # last character goes too.
  defp unquote_identifier(<<?[, _::binary>> = raw), do: strip_quotes(raw, ?])

  defp unquote_identifier(<<q, _::binary>> = raw) do
    inner = strip_quotes(raw, q)

    if :binary.match(inner, <<q, q>>) == :nomatch,
      do: inner,
      else: :binary.replace(inner, <<q, q>>, <<q>>, [:global])
  end

  defp strip_quotes(raw, close) do
    size = byte_size(raw)

    if size >= 2 and :binary.last(raw) == close,
      do: :binary.part(raw, 1, size - 2),
      else: String.slice(raw, 1..-2//1)
  end

  # ---------------------------------------------------------------------------
  # Annotation: each lexeme with its clause, and whether its names reach the
  # result
  # ---------------------------------------------------------------------------

  # One pass over the lexemes. Each frame is one level of parentheses: the
  # clause its lexemes sit in (:none, :with, :select, :from, :join_cond,
  # :order, :group, :other, or :table and :table_order), whether the names of its select list reach
  # the result, the level it is (a number for each frame, so that an ORDER
  # BY finds its own query's output columns), whether it holds the arguments
  # of a scalar function in FROM, and the level whose select items an integer
  # in it may name (`ORDER BY (1)`, `ROLLUP (1, 2)`, `DISTINCT ON (1)`), or
  # nil. The names reach the result at the top level and in a derived table
  # or CTE body nested only in such frames: a consumer reads them through
  # `*` or by name, both checked where they appear. They don't in an
  # expression, a function's arguments or a WHERE subquery.
  #
  # Each lexeme becomes `{lexeme, reaches?, clause, level}`; an integer
  # becomes `{:int, digits, level}`, the level it names a select item of
  # when it is a whole sort or grouping item, or nil.
  defp annotate(lexemes) do
    notes = %{relations: %{}, ctes: %{}, outputs: %{}, set_op?: false, alias_list?: false}
    top = {:none, true, 0, false, nil}
    {out, notes} = annotate(lexemes, :bof, :bof, [top], 0, nil, [], notes)
    Map.put(notes, :out, out)
  end

  defp annotate([lexeme | rest], prev, prev2, [frame | _] = frames, levels, scalar, acc, notes) do
    {clause, reaches?, level, _scalar?, position} = frame
    next = next_of(rest)

    notes =
      notes
      |> note(scalar, lexeme, prev, prev2, next, clause)
      |> note_output(lexeme, prev, clause, level)

    entry = {entry_lexeme(lexeme, clause, prev, next, level, position), reaches?, clause, level}
    scalar = scalar_after(scalar, lexeme, clause)

    case step(lexeme, frames, levels, clause, prev, prev2) do
      {frames, levels} ->
        annotate(rest, lexeme, prev, frames, levels, scalar, [entry | acc], notes)

      {frames, levels, scalar} ->
        annotate(rest, lexeme, prev, frames, levels, scalar, [entry | acc], notes)
    end
  end

  defp annotate([], _prev, _prev2, _frames, _levels, _scalar, acc, notes),
    do: {:lists.reverse(acc), notes}

  defp next_of([next | _]), do: next
  defp next_of([]), do: :eof

  # Relation names and aliases (in FROM) and CTE names (in WITH), so that a
  # whole-row reference to one can be found; and the renaming forms. Right
  # after a scalar function's arguments close in FROM (`scalar` is :call),
  # its alias names a value, not a row, and so does a column alias list
  # after it.
  defp note(notes, :call, {:name, _, _}, _prev, _prev2, _next, :from), do: notes
  defp note(notes, {:alias, alias}, "(", alias, _prev2, _next, :from), do: notes

  defp note(notes, _scalar, {:name, _raw, down}, _prev, _prev2, next, :from) when next != ".",
    do: %{notes | relations: Map.put(notes.relations, down, true)}

  defp note(notes, _scalar, "(", prev, prev2, _next, :from) do
    if prev in [{:kw, "as"}, ")"] or (name?(prev) and alias_position?(prev2)),
      do: %{notes | alias_list?: true},
      else: notes
  end

  defp note(notes, _scalar, {:name, _raw, down}, prev, _prev2, next, :with)
       when prev in [{:kw, "with"}, {:kw, "recursive"}, ","] do
    %{
      notes
      | relations: Map.put(notes.relations, down, true),
        ctes: Map.put(notes.ctes, down, true),
        alias_list?: notes.alias_list? or next == "("
    }
  end

  defp note(notes, _scalar, {:kw, op}, _prev, _prev2, _next, _clause) when op in @set_ops,
    do: %{notes | set_op?: true}

  defp note(notes, _scalar, _lexeme, _prev, _prev2, _next, _clause), do: notes

  # The output columns' aliases, for ORDER BY.
  defp note_output(notes, {:name, _raw, down}, {:kw, "as"}, :select, level),
    do: %{notes | outputs: Map.put(notes.outputs, {level, down}, true)}

  defp note_output(notes, _lexeme, _prev, _clause, _level), do: notes

  # After a scalar function's arguments close in FROM: an optional AS, then
  # its alias, then perhaps the alias's column list.
  defp scalar_after(:call, {:kw, "as"}, :from), do: :call
  defp scalar_after(:call, {:name, _, _} = alias, :from), do: {:alias, alias}
  defp scalar_after(_scalar, _lexeme, _clause), do: nil

  # A name follows a table or subquery here, so a "(" after it opens a column
  # alias list rather than a function's arguments.
  defp alias_position?(lexeme), do: name?(lexeme) or lexeme in [")", {:kw, "as"}]

  defp name?({:name, _, _}), do: true
  defp name?(_), do: false

  # A whole ORDER BY or GROUP BY item that is an integer names the select
  # item at that position, and so does a whole item in parentheses of one,
  # of ROLLUP, CUBE, GROUPING SETS or DISTINCT ON. An integer followed by an
  # operator is an operand.
  defp entry_lexeme({:int, n}, clause, prev, next, level, position) do
    cond do
      clause in @position_clauses and prev in [{:kw, "by"}, ","] and not operator?(next) ->
        {:int, n, level}

      clause == :none and prev in ["(", ","] and next in [")", ","] ->
        {:int, n, position}

      true ->
        {:int, n, nil}
    end
  end

  defp entry_lexeme(lexeme, _clause, _prev, _next, _level, _position), do: lexeme

  defp operator?(next), do: is_binary(next) and next not in [",", ")", ";"]

  defp step("(", [frame | _] = frames, levels, clause, prev, prev2) do
    {_clause, reaches?, level, _scalar?, position} = frame
    levels = levels + 1
    scalar? = clause == :from and scalar_function?(prev)
    position = paren_position(clause, prev, prev2, level, position)
    {[{:none, reaches? and clause in [:from, :with], levels, scalar?, position} | frames], levels}
  end

  defp step(")", [_top] = frames, levels, _clause, _prev, _prev2), do: {frames, levels}

  defp step(")", [{_, _, _, scalar?, _} | frames], levels, _clause, _prev, _prev2),
    do: {frames, levels, if(scalar?, do: :call)}

  defp step({:kw, kw}, [frame | parents] = frames, levels, clause, _prev, _prev2) do
    case keyword_clause(kw, clause) do
      ^clause -> {frames, levels}
      clause -> {[put_elem(frame, 0, clause) | parents], levels}
    end
  end

  defp step(_lexeme, frames, levels, _clause, _prev, _prev2), do: {frames, levels}

  defp keyword_clause("select", _clause), do: :select
  defp keyword_clause("with", clause) when clause in [:none, :table, :table_order], do: :with
  defp keyword_clause("from", :select), do: :from

  # `TABLE t` reads as `SELECT * FROM t ...`, so its ORDER BY sorts by the
  # table's columns, by position too. Otherwise :table and :table_order are
  # :none.
  defp keyword_clause("table", :none), do: :table
  defp keyword_clause("order", :table), do: :table_order

  defp keyword_clause(kw, :table_order) when kw in @clause_ends or kw == "group",
    do: :table

  defp keyword_clause("join", clause) when clause in [:from, :join_cond], do: :from
  defp keyword_clause(kw, :from) when kw in ["on", "using"], do: :join_cond
  defp keyword_clause("order", clause) when clause in @query_clauses, do: :order
  defp keyword_clause("group", clause) when clause in @query_clauses, do: :group

  defp keyword_clause(kw, clause) when kw in @clause_ends and clause in @query_clauses,
    do: :other

  defp keyword_clause(kw, _clause) when kw in @set_ops, do: :none
  defp keyword_clause(_kw, clause), do: clause

  # The level whose select items a whole integer item in a "(" opened here
  # names: this frame's own after ORDER BY or GROUP BY, its enclosing one's
  # in a nested list, nil in a function's arguments.
  defp paren_position(:select, {:kw, "on"}, {:kw, "distinct"}, level, _position), do: level

  defp paren_position(clause, prev, _prev2, level, _position) when clause in @position_clauses,
    do: if(item_start?(prev), do: level)

  defp paren_position(:none, prev, _prev2, _level, position),
    do: if(item_start?(prev), do: position)

  defp paren_position(_clause, _prev, _prev2, _level, _position), do: nil

  defp item_start?({:name, _raw, down}), do: down in @grouping_sets
  defp item_start?(prev), do: prev in [{:kw, "by"}, ",", "("]

  defp scalar_function?({:name, _raw, down}), do: down in @scalar_functions
  defp scalar_function?(_lexeme), do: false

  # ---------------------------------------------------------------------------
  # Verification: one pass over the annotated lexemes
  # ---------------------------------------------------------------------------

  defp verify(%{alias_list?: true}, _matcher, _rels) do
    {:error,
     "Query renames the columns of a table with protected columns through a column " <>
       "alias list, which Lotus can't check against column policies. Alias columns in " <>
       "the select list instead."}
  end

  # `context` holds what the whole statement tells; `cache` what is worked
  # out from it only when needed: whether a name is protected, the sources
  # FROM binds, the select lists, the outcome of a position.
  defp verify(%{out: out} = notes, matcher, rels) do
    context = %{
      matcher: matcher,
      names: column_names(matcher),
      rels: rels,
      out: out,
      relations: notes.relations,
      outputs: notes.outputs,
      ctes: notes.ctes,
      set_op?: notes.set_op?
    }

    with {:ok, cache} <- walk(out, :bof, :bof, {:bof, []}, {:bof, []}, context, %{}),
         do: {:ok, column_sources(context, cache)}
  end

  # Besides the lexemes before it, each one carries what precedes its
  # `schema.table.` qualifier and the qualifier's names, so that the walk
  # never looks back further than two lexemes.
  defp walk([{lexeme, _, _, _} = entry | rest], prev, prev2, chain1, chain2, ctx, cache) do
    chain = chain(prev, prev2, chain2)

    case check_entry(entry, prev, prev2, chain, rest, ctx, cache) do
      {:ok, cache} -> walk(rest, lexeme, prev, chain, chain1, ctx, cache)
      {:error, _message} = error -> error
    end
  end

  defp walk([], _prev, _prev2, _chain1, _chain2, _ctx, cache), do: {:ok, cache}

  defp chain(".", {:name, raw, _down}, {before, qualifier}), do: {before, qualifier ++ [raw]}
  defp chain(prev, _prev2, _chain2), do: {prev, []}

  defp check_entry(
         {{:name, raw, down}, _, clause, _} = entry,
         prev,
         _prev2,
         chain,
         rest,
         ctx,
         cache
       ) do
    if definition?(prev, clause),
      do: {:ok, cache},
      else: check_name(raw, down, entry, prev, chain, rest, ctx, cache)
  end

  # `count(*)` reads no column; `*` and `t.*` as select items keep the names,
  # except across a set operation; `*` between operands multiplies them.
  defp check_entry({"*", _, clause, _}, prev, prev2, {before, _qualifier}, rest, ctx, cache) do
    next = next_lexeme(rest)

    cond do
      prev == "(" and next == ")" ->
        {:ok, cache}

      clause == :select and before in @select_starts and next in [")" | @item_ends] ->
        star_ok(ctx, cache)

      prev == "." ->
        whole_row_error(qualifier(prev2))

      true ->
        {:ok, cache}
    end
  end

  defp check_entry({{:int, n, level}, _, _, _}, _prev, _prev2, _chain, _rest, ctx, cache)
       when level != nil,
       do: check_position(n, level, ctx, cache)

  # `TABLE t` is `SELECT * FROM t`.
  defp check_entry({{:kw, "table"}, _, :none, _}, _prev, _prev2, _chain, _rest, ctx, cache),
    do: star_ok(ctx, cache)

  defp check_entry({{:kw, "natural"}, _, _, _}, _prev, _prev2, _chain, _rest, _ctx, _cache),
    do: natural_join_error()

  defp check_entry({:escaped_name, _, _, _}, _prev, _prev2, _chain, _rest, _ctx, _cache) do
    {:error,
     "Query uses a Unicode-escaped identifier (U&\"...\"), which Lotus can't check " <>
       "against column policies. Write the name plainly."}
  end

  defp check_entry(_entry, _prev, _prev2, _chain, _rest, _ctx, cache), do: {:ok, cache}

  # A protected column may stand only as a whole select item whose names
  # reach the result; any other name may be a whole row.
  defp check_name(raw, down, {_, reaches?, clause, level}, prev, chain, rest, ctx, cache) do
    {before, qualifier} = chain

    case protected?(raw, down, qualifier, ctx, cache) do
      {true, cache} ->
        if reaches? and clause == :select and not ctx.set_op? and before in @select_starts and
             bare_end?(rest, down),
           do: {:ok, cache},
           else: protected_error(raw)

      {false, cache} ->
        if whole_row?(down, clause, level, prev, rest, ctx),
          do: whole_row_error(raw),
          else: {:ok, cache}
    end
  end

  defp star_ok(%{set_op?: true}, _cache), do: set_op_error()
  defp star_ok(_ctx, cache), do: {:ok, cache}

  # An output alias or a CTE name names something; it reads nothing.
  defp definition?({:kw, "as"}, _clause), do: true
  defp definition?(prev, :with), do: prev in [{:kw, "with"}, {:kw, "recursive"}, ","]
  defp definition?(_prev, _clause), do: false

  defp bare_end?([{{:kw, "as"}, _, _, _} | rest], down) do
    case rest do
      [{{:name, _raw, ^down}, _, _, _} | rest] -> next_lexeme(rest) in @item_ends
      _ -> false
    end
  end

  defp bare_end?(rest, _down), do: next_lexeme(rest) in @item_ends

  defp whole_row?(down, clause, level, prev, rest, ctx) do
    next = next_lexeme(rest)

    clause != :from and Map.has_key?(ctx.relations, down) and prev != "." and
      next not in [".", "("] and not sorts_by_output?(down, clause, level, prev, next, ctx)
  end

  # A whole ORDER BY item that names an output column of its own query sorts
  # by that column: the database reads an output name before a relation's
  # row there. Not inside an expression, where output names don't reach.
  defp sorts_by_output?(down, clause, level, prev, next, ctx) do
    clause == :order and prev in [{:kw, "by"}, ","] and sort_item_end?(next) and
      Map.has_key?(ctx.outputs, {level, down})
  end

  defp sort_item_end?({:name, _raw, down}), do: down in @sort_modifiers
  defp sort_item_end?(next), do: next in @sort_item_ends

  defp qualifier({:name, raw, _down}), do: raw
  defp qualifier(_), do: "*"

  # ---------------------------------------------------------------------------
  # Protection: by name, or by the relation a qualifier names
  # ---------------------------------------------------------------------------

  # A name qualified by a relation preflight found (`o.ssn` with `orders o`)
  # reads that relation's column, protected only if a policy for it is. Any
  # other name may read any relation's column of that name.
  defp protected?(raw, down, qualifier, ctx, cache) do
    {protected?, cache} = protected_by_name?(raw, down, ctx, cache)

    if protected? and qualifier != [] do
      case resolve(qualifier, ctx, cache) do
        {nil, cache} -> {true, cache}
        {relation, cache} -> {policy_protects?(ctx.matcher, [relation], raw, down), cache}
      end
    else
      {protected?, cache}
    end
  end

  # Asked each time a name stands, unless no column rule can name it.
  defp protected_by_name?(raw, down, %{names: names} = ctx, cache) do
    if names == :any or Map.has_key?(names, down),
      do: {policy_protects?(ctx.matcher, ctx.rels, raw, down), cache},
      else: {false, cache}
  end

  # The column names the matcher's column rules spell out exactly, in
  # lowercase, or :any when one is a pattern. A rule's column matches a name
  # only when the two are equal ignoring case (`Lotus.Visibility.Matcher`),
  # so no other name can be protected and the matcher needs no asking about
  # it. Anything this doesn't recognize is read as :any.
  defp column_names(%Matcher{column: %{patterns: [], exact: exact} = rules}) when is_map(exact) do
    columns =
      Enum.map(Map.get(rules, :schema_table, []), &elem(&1, 2)) ++
        Enum.map(Map.get(rules, :table, []), &elem(&1, 1))

    if Enum.all?(columns, &(is_binary(&1) and &1 != "*")),
      do: Map.new(columns ++ Map.keys(exact), &{String.downcase(&1), true}),
      else: :any
  end

  defp column_names(_matcher), do: :any

  defp policy_protects?(matcher, rels, raw, down) do
    restricts?(Visibility.column_policy_for(matcher, rels, raw)) or
      (down != raw and restricts?(Visibility.column_policy_for(matcher, rels, down)))
  end

  defp restricts?(%{action: action}), do: action != :allow
  defp restricts?(_policy), do: false

  # Whether a name is protected once the sources are known (a select item's).
  defp protected_name?(raw, down, qualifier, ctx, cache) do
    {protected?, _cache} = protected?(raw, down, qualifier, ctx, cache)
    protected?
  end

  # `t.*` over a relation with no protected column, wherever it stands.
  defp safe_star?(qualifier, ctx, cache) do
    case resolve(qualifier, ctx, cache) do
      {nil, _cache} -> false
      {relation, _cache} -> not Matcher.restricts_columns?(ctx.matcher, [relation])
    end
  end

  # ---------------------------------------------------------------------------
  # Qualifiers: the relation a qualified name reads, when it can be told
  # ---------------------------------------------------------------------------

  # What FROM binds to `name`, and how often the name stands anywhere but
  # before a dot. A statement with a few qualifiers is scanned for each; one
  # with more has all its names worked out at once, so the check stays
  # linear in the statement's size.
  defp bound(name, ctx, cache) do
    key = {:bound, name}

    case cache do
      %{^key => bound} ->
        {bound, cache}

      %{sources: {binds, counts}} ->
        {{Map.get(binds, name, []), Map.get(counts, name, 0)}, cache}

      %{scans: @max_scans} ->
        bound(name, ctx, with_sources(cache, ctx))

      _ ->
        bound = scan(ctx.out, :bof, name, ctx.ctes, [], 0)
        {bound, cache |> Map.put(key, bound) |> Map.update(:scans, 1, &(&1 + 1))}
    end
  end

  defp scan([{lexeme, _reaches?, clause, _level} | rest] = entries, prev, name, ctes, binds, n) do
    n =
      case lexeme do
        {:name, _raw, ^name} -> if next_lexeme(rest) == ".", do: n, else: n + 1
        _ -> n
      end

    case binding(lexeme, clause, prev, entries, rest, ctes) do
      {^name, target} -> scan(rest, lexeme, name, ctes, [target | binds], n)
      _ -> scan(rest, lexeme, name, ctes, binds, n)
    end
  end

  defp scan([], _prev, _name, _ctes, binds, n), do: {binds, n}

  defp with_sources(%{sources: _} = cache, _ctx), do: cache
  defp with_sources(cache, ctx), do: Map.put(cache, :sources, sources(ctx.out, ctx.ctes))

  # What the statement binds in FROM and JOIN, by lowercase name: a table
  # (`{:table, path}`, under its alias or else its name) or something whose
  # columns can be anything (`:opaque`: a CTE, a derived table, a function);
  # and how often each name stands anywhere but before a dot.
  defp sources(out, ctes), do: sources(out, :bof, ctes, %{}, %{})

  defp sources([{lexeme, _reaches?, clause, _level} | rest] = entries, prev, ctes, binds, counts) do
    counts =
      case lexeme do
        {:name, _raw, down} ->
          if next_lexeme(rest) == ".", do: counts, else: Map.update(counts, down, 1, &(&1 + 1))

        _ ->
          counts
      end

    binds =
      case binding(lexeme, clause, prev, entries, rest, ctes) do
        nil -> binds
        {name, target} -> Map.update(binds, name, [target], &[target | &1])
      end

    sources(rest, lexeme, ctes, binds, counts)
  end

  defp sources([], _prev, _ctes, binds, counts), do: {binds, counts}

  defp binding({:name, _, _}, :from, prev, entries, _rest, ctes) do
    if prev in @table_starts, do: table_binding(entries, ctes)
  end

  defp binding(")", _clause, _prev, _entries, [{_lexeme, _reaches?, :from, _level} | _] = rest, _) do
    case alias_of(rest) do
      nil -> nil
      {_raw, down} -> {down, :opaque}
    end
  end

  defp binding(_lexeme, _clause, _prev, _entries, _rest, _ctes), do: nil

  defp table_binding(entries, ctes) do
    {path, rest} = path_of(entries, [])
    path = Enum.map(path, &downcase/1)

    cond do
      next_lexeme(rest) == "(" -> nil
      cte?(path, ctes) -> {alias_name(rest, List.last(path)), :opaque}
      true -> {alias_name(rest, List.last(path)), {:table, path}}
    end
  end

  defp alias_name(rest, default) do
    case alias_of(rest) do
      nil -> default
      {_raw, down} -> down
    end
  end

  defp alias_of([{{:kw, "as"}, _, _, _}, {{:name, raw, down}, _, _, _} | _]), do: {raw, down}
  defp alias_of([{{:name, raw, down}, _, _, _} | _]), do: {raw, down}
  defp alias_of(_rest), do: nil

  # The relation of `rels` a qualifier (`[alias]`, `[table]` or
  # `[schema, table]`) names, or nil when it can't be told for sure: the name
  # is bound more than once, or stands elsewhere too (a column, another
  # alias), or binds no table preflight found, exactly once.
  defp resolve(qualifier, ctx, cache) when length(qualifier) in [1, 2] do
    path = Enum.map(qualifier, &downcase/1)
    {bound, cache} = bound(List.last(path), ctx, cache)
    {resolve_path(path, bound, ctx.rels), cache}
  end

  defp resolve(_qualifier, _ctx, cache), do: {nil, cache}

  defp resolve_path(path, bound, rels) do
    with {[{:table, table}], 1} <- bound,
         {:ok, path} <- relation_path(path, table),
         [relation] <- Enum.filter(rels, &relation?(&1, path)) do
      relation
    else
      _ -> nil
    end
  end

  # `[alias]` names the table it is bound to; `[schema, table]` names a table
  # bound under its own name.
  defp relation_path([_alias], table), do: {:ok, table}
  defp relation_path([_schema, name] = path, table) when table in [[name], path], do: {:ok, path}
  defp relation_path(_qualifier, _table), do: :error

  defp relation?({_schema, table}, [name]), do: String.downcase(table) == name

  defp relation?({schema, table}, [schema_name, name]),
    do:
      is_binary(schema) and String.downcase(schema) == schema_name and
        String.downcase(table) == name

  defp relation?(_relation, _path), do: false

  # ---------------------------------------------------------------------------
  # Positions: ORDER BY 1, GROUP BY 1
  # ---------------------------------------------------------------------------

  # A whole ORDER BY or GROUP BY item that is an integer names the select
  # item at that position, so sorting or grouping by it reveals how that
  # column's values order or repeat whatever the result shows of them. The
  # position must be a select item that is no protected column, with no `*`
  # up to it, whose width can't be known here. Each select list of the
  # query at `level` (a set operation has one per branch) must be safe.
  defp check_position(n, level, ctx, cache) do
    key = {:position, level, n}

    case cache do
      %{^key => :ok} ->
        {:ok, cache}

      %{^key => error} ->
        error

      _ ->
        cache = with_lists(cache, ctx)
        lists = Map.get(cache.lists, level, [])

        outcome =
          if lists == [],
            do: {:error, unknown_position()},
            else: Enum.find_value(lists, :ok, &list_position(&1, String.to_integer(n)))

        case outcome do
          :ok -> {:ok, Map.put(cache, key, :ok)}
          {:error, message} -> {:error, "Query sorts or groups by position #{n}, " <> message}
        end
    end
  end

  # Up to a `*` the position is the item's. From a `t.*` over a relation
  # with no protected column (whose width isn't known here) it may be any
  # later item, so all of those must be safe.
  defp list_position({items, first_star, from_star_safe?}, n) do
    cond do
      n < 1 ->
        {:error, unknown_position()}

      first_star != nil and first_star <= n ->
        if(from_star_safe?, do: nil, else: {:error, unknown_position()})

      n > tuple_size(items) ->
        {:error, unknown_position()}

      true ->
        item_position(elem(items, n - 1))
    end
  end

  defp item_position({_item, nil}), do: nil
  defp item_position({_item, name}), do: {:error, protected_position(name)}

  defp with_lists(%{lists: _} = cache, _ctx), do: cache

  defp with_lists(cache, ctx) do
    cache = with_sources(cache, ctx)

    lists =
      ctx.out
      |> collect_lists(%{})
      |> Map.new(fn {level, lists} ->
        {level, lists |> :lists.reverse() |> Enum.map(&prepare_list(&1, ctx, cache))}
      end)

    Map.put(cache, :lists, lists)
  end

  # The select items of each SELECT, by level, as the lexemes of that level
  # (what nested parentheses hold is checked where it stands). Lists, items
  # and lexemes are gathered in reverse.
  defp collect_lists([{lexeme, _reaches?, clause, level} | rest], lists) do
    lists =
      case {lexeme, clause} do
        {{:kw, "select"}, _clause} ->
          Map.update(lists, level, [[[]]], &[[[]] | &1])

        {",", :select} ->
          update_list(lists, level, &[[] | &1])

        {lexeme, :select} ->
          update_list(lists, level, fn [item | items] -> [[lexeme | item] | items] end)

        _ ->
          lists
      end

    collect_lists(rest, lists)
  end

  defp collect_lists([], lists), do: lists

  defp update_list(lists, level, fun) do
    case lists do
      %{^level => [items | rest]} -> %{lists | level => [fun.(items) | rest]}
      _ -> lists
    end
  end

  # Each item with the first protected name it reads; the position of the
  # first `*` or `t.*` (from 1); and whether every item from there is safe.
  defp prepare_list(reversed_items, ctx, cache) do
    items = reversed_items |> list_items() |> Enum.map(&clean_item/1)

    first_star = Enum.find_index(items, &star_item?/1)

    from_star_safe? =
      first_star != nil and
        items |> Enum.drop(first_star) |> Enum.all?(&safe_item?(&1, ctx, cache))

    items = items |> Enum.map(&{&1, protected_item(&1, ctx, cache)}) |> List.to_tuple()
    {items, first_star && first_star + 1, from_star_safe?}
  end

  # The items of a list gathered in reverse, in order, without the keywords
  # that start the first item.
  defp list_items(reversed_items) do
    [first | items] = Enum.reduce(reversed_items, [], &[:lists.reverse(&1) | &2])

    first =
      case first do
        [{:kw, "distinct"}, {:kw, "on"}, "(" | rest] -> rest
        [{:kw, kw} | rest] when kw in ["distinct", "all"] -> rest
        _ -> first
      end

    [first | items]
  end

  # Without the keywords that end the list.
  defp clean_item(item), do: Enum.reject(item, &list_keyword?/1)

  defp list_keyword?({:kw, kw}), do: kw != "as"
  defp list_keyword?(_lexeme), do: false

  # `*` or `t.*`.
  defp star_item?(["*"]), do: true
  defp star_item?([{:name, _, _}, "." | rest]), do: star_item?(rest)
  defp star_item?(_item), do: false

  defp safe_item?(["*"], _ctx, _cache), do: false

  defp safe_item?(item, ctx, cache) do
    if star_item?(item),
      do: item |> Enum.drop(-2) |> Enum.flat_map(&raw_name/1) |> safe_star?(ctx, cache),
      else: protected_item(item, ctx, cache) == nil
  end

  defp raw_name({:name, raw, _down}), do: [raw]
  defp raw_name(_lexeme), do: []

  # The first protected name the item reads (an alias after AS reads none).
  defp protected_item(item, ctx, cache), do: protected_item(item, :bof, :bof, [], [], ctx, cache)

  defp protected_item([lexeme | rest], prev, prev2, qualifier1, qualifier2, ctx, cache) do
    qualifier =
      case {prev, prev2} do
        {".", {:name, raw, _down}} -> qualifier2 ++ [raw]
        _ -> []
      end

    case lexeme do
      {:name, raw, down} when prev != {:kw, "as"} ->
        if protected_name?(raw, down, qualifier, ctx, cache),
          do: raw,
          else: protected_item(rest, lexeme, prev, qualifier, qualifier1, ctx, cache)

      _ ->
        protected_item(rest, lexeme, prev, qualifier, qualifier1, ctx, cache)
    end
  end

  defp protected_item([], _prev, _prev2, _qualifier1, _qualifier2, _ctx, _cache), do: nil

  # ---------------------------------------------------------------------------
  # Sources: the relation each result column comes from
  # ---------------------------------------------------------------------------

  # The top-level select list's items up to the first `*` or `t.*`, whose
  # width can't be known here. A set operation's result takes the first
  # branch's names over every branch's values, so it has none.
  defp column_sources(%{set_op?: true}, _cache), do: nil

  defp column_sources(ctx, cache) do
    case ctx.out |> collect_lists(%{}) |> Map.get(0) do
      [reversed_items] ->
        reversed_items
        |> list_items()
        |> Enum.take_while(&(not star_item?(clean_item(&1))))
        |> Enum.map_reduce(cache, &item_source(&1, ctx, &2))
        |> elem(0)

      _ ->
        nil
    end
  end

  # A qualified column as is (`o.ssn`, `public.orders.ssn`, perhaps `AS ssn`)
  # comes from the relation its qualifier names, when that can be told.
  defp item_source(item, ctx, cache) do
    with {[_ | _] = qualifier, [{:name, _raw, down} | rest]} <- split_qualifier(item, []),
         true <- bare_tail?(rest, down),
         {{_schema, _table} = relation, cache} <- resolve(qualifier, ctx, cache) do
      {{:relation, relation}, cache}
    else
      _ -> {:unresolved, cache}
    end
  end

  defp split_qualifier([{:name, raw, _down}, "." | rest], acc),
    do: split_qualifier(rest, [raw | acc])

  defp split_qualifier(rest, acc), do: {:lists.reverse(acc), rest}

  # The last item ends with the keyword that ends the list (`FROM`).
  defp bare_tail?([], _down), do: true
  defp bare_tail?([{:kw, kw}], _down), do: kw != "as"
  defp bare_tail?([{:kw, "as"}, {:name, _raw, down}], down), do: true
  defp bare_tail?([{:kw, "as"}, {:name, _raw, down}, {:kw, kw}], down), do: kw != "as"
  defp bare_tail?(_rest, _down), do: false

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  defp protected_error(name) do
    {:error,
     "Query uses protected column #{name} in a way Lotus can't check against its column " <>
       "policy: renamed, wrapped in an expression, or read outside a select list whose " <>
       "names reach the result (in WHERE, ORDER BY, a filter or a sort). Select it as " <>
       "is (SELECT #{name}), or leave it out."}
  end

  defp whole_row_error(name) do
    {:error,
     "Query reads whole rows of #{name}, which has protected columns, so Lotus can't " <>
       "apply their column policies. Select the columns instead."}
  end

  defp natural_join_error do
    {:error,
     "Query joins with NATURAL over a table with protected columns, which compares " <>
       "columns the statement doesn't name, so Lotus can't check them against column " <>
       "policies. Join with ON and name the columns."}
  end

  defp set_op_error do
    {:error,
     "Query combines * with UNION, INTERSECT or EXCEPT over a table with protected " <>
       "columns, which renames them after the first branch. Select the columns by name."}
  end

  defp protected_position(name) do
    "protected column #{name}, which reveals how its values order or repeat whatever " <>
      "the result shows of them. Sort or group by another column."
  end

  defp unknown_position do
    "which Lotus can't match to a select item (it follows a * or is past the select " <>
      "list), so it can't check it against column policies. Sort by the column's name."
  end
end
