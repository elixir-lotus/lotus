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
    * combine `*` or `TABLE t` with `UNION`, `INTERSECT` or `EXCEPT`, whose
      result takes the first branch's column names;
    * sort or group by the position of a protected column (`SELECT ssn ...
      ORDER BY 1`, also in `GROUP BY`, `DISTINCT ON`, `ROLLUP`, `CUBE` and
      `GROUPING SETS`), which reveals how its values order or repeat, or by a
      position it can't match to a select item (at or after a `*`).

  A column is protected by name, whatever relation it is read from, unless
  the name is qualified (`o.ssn`, `orders.ssn`, `public.orders.ssn`) by a
  relation the check can tell for sure: an alias or table name bound exactly
  once in the statement's FROM and JOIN clauses, standing nowhere else, to a
  table preflight found (not a CTE, derived table or function). Such a name
  reads that table's column, protected only if a policy for that table is.

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

  @select_starts [{:kw, "select"}, {:kw, "distinct"}, {:kw, "all"}, ","]
  @item_ends [",", {:kw, "from"}, :eof]
  @clause_ends ~w(where group having order limit offset fetch window qualify returning)
  @set_ops ~w(union intersect except minus)
  @query_clauses [:select, :from, :join_cond, :order, :group, :other]
  @position_clauses [:order, :group, :table_order]
  @table_starts [{:kw, "from"}, {:kw, "join"}, ",", {:kw, "lateral"}, {:kw, "only"}]

  # Functions in FROM whose rows are a number or a time, never a table's
  # row: their alias is no whole-row reference. Their arguments are checked
  # as anything else is.
  @scalar_functions ~w(generate_series generate_subscripts)

  # What may follow a whole ORDER BY item.
  @sort_item_ends [",", ")", ";", :eof, {:kw, "limit"}, {:kw, "offset"}, {:kw, "fetch"}]
  @sort_modifiers ~w(asc desc nulls)

  @doc """
  Checks `sql` against the column policies of `matcher` for the relations
  preflight found. Returns `:ok` or `{:error, message}`.
  """
  @spec check(String.t(), Profile.t(), Matcher.t(), Relations.outcome()) ::
          :ok | {:error, String.t()}
  def check(sql, %Profile{} = profile, %Matcher{} = matcher, relations) when is_binary(sql) do
    rels = Relations.to_list(relations)
    restricted? = Matcher.restricts_columns?(matcher, rels)

    if restricted? do
      sql
      |> lex(profile)
      |> annotate()
      |> verify(matcher, rels)
    else
      :ok
    end
  end

  def check(_sql, _profile, _matcher, _relations), do: :ok

  @doc false
  # The tables a statement names in FROM and JOIN, as name paths
  # (`[schema, table]` or `[table]`), CTEs and functions left out. A dialect
  # whose plan can omit a table the planner proved empty (`WHERE false`)
  # resolves these to make sure preflight still sees it.
  @spec table_names(String.t(), Profile.t()) :: [[String.t()]]
  def table_names(sql, %Profile{} = profile) when is_binary(sql) do
    %{out: out, ctes: ctes} = sql |> lex(profile) |> annotate()

    0..(tuple_size(out) - 1)//1
    |> Enum.flat_map(fn i ->
      with {{:name, _}, _reaches?, :from, _level} <- elem(out, i),
           true <- at(out, i - 1) in @table_starts,
           {path, next} <- name_path(out, i, []),
           true <- next != "(",
           false <- cte?(path, ctes) do
        [path]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp cte?([name], ctes), do: MapSet.member?(ctes, String.downcase(name))
  defp cte?(_path, _ctes), do: false

  defp name_path(out, i, acc) do
    {:name, name} = at(out, i)

    if at(out, i + 1) == "." and name?(at(out, i + 2)),
      do: name_path(out, i + 2, [name | acc]),
      else: {Enum.reverse([name | acc]), at(out, i + 1)}
  end

  # A name qualified by a relation preflight found (`o.ssn` with `orders o`)
  # reads that relation's column, protected only if a policy for it is. Any
  # other name may read any relation's column of that name.
  defp protected?(matcher, rels, name, nil), do: protected?(matcher, rels, name)

  defp protected?(matcher, rels, name, relation),
    do: protected?(matcher, rels, name) and protected?(matcher, [relation], name)

  defp protected?(matcher, rels, name) do
    Enum.any?(Enum.uniq([name, String.downcase(name)]), fn n ->
      case Visibility.column_policy_for(matcher, rels, n) do
        %{action: action} when action != :allow -> true
        _ -> false
      end
    end)
  end

  # `t.*` over a relation with no protected column, wherever it stands.
  defp safe_star?(_matcher, nil), do: false
  defp safe_star?(matcher, relation), do: not Matcher.restricts_columns?(matcher, [relation])

  # ---------------------------------------------------------------------------
  # Qualifiers: the relation a qualified name reads, when it can be told
  # ---------------------------------------------------------------------------

  # What the statement binds in FROM and JOIN, by lowercase name: a table
  # (`{:table, path}`, under its alias or else its name) or something whose
  # columns can be anything (`:opaque`: a CTE, a derived table, a function);
  # and how often each name stands anywhere but before a dot.
  defp sources(out, ctes) do
    Enum.reduce(0..(tuple_size(out) - 1)//1, {%{}, %{}}, fn i, {bindings, counts} ->
      counts =
        case elem(out, i) do
          {{:name, name}, _reaches?, _clause, _level} ->
            if at(out, i + 1) == ".",
              do: counts,
              else: Map.update(counts, String.downcase(name), 1, &(&1 + 1))

          _ ->
            counts
        end

      case binding_at(out, i, ctes) do
        nil -> {bindings, counts}
        {name, target} -> {Map.update(bindings, name, [target], &[target | &1]), counts}
      end
    end)
  end

  defp binding_at(out, i, ctes) do
    case elem(out, i) do
      {{:name, _}, _reaches?, :from, _level} ->
        if at(out, i - 1) in @table_starts, do: table_binding(out, i, ctes)

      {")", _reaches?, _clause, _level} ->
        with {_lexeme, _reaches?, :from, _level} <- raw_at(out, i + 1),
             name when is_binary(name) <- alias_at(out, i + 1) do
          {String.downcase(name), :opaque}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp table_binding(out, i, ctes) do
    {path, j} = path_at(out, i, [])
    path = Enum.map(path, &String.downcase/1)

    cond do
      at(out, j) == "(" -> nil
      cte?(path, ctes) -> {alias_at(out, j, List.last(path)), :opaque}
      true -> {alias_at(out, j, List.last(path)), {:table, path}}
    end
  end

  defp path_at(out, i, acc) do
    {:name, name} = at(out, i)

    if at(out, i + 1) == "." and name?(at(out, i + 2)),
      do: path_at(out, i + 2, [name | acc]),
      else: {Enum.reverse([name | acc]), i + 1}
  end

  defp alias_at(out, j, default) do
    case alias_at(out, j) do
      nil -> default
      name -> String.downcase(name)
    end
  end

  defp alias_at(out, j) do
    case {at(out, j), at(out, j + 1)} do
      {{:kw, "as"}, {:name, name}} -> name
      {{:name, name}, _next} -> name
      _ -> nil
    end
  end

  # The relation of `rels` a qualifier (`[alias]`, `[table]` or
  # `[schema, table]`) names, or nil when it can't be told for sure: the name
  # is bound more than once, or stands elsewhere too (a column, another
  # alias), or binds no table preflight found, exactly once.
  defp resolve([], _sources, _rels), do: nil

  defp resolve(qualifier, {bindings, counts}, rels) when length(qualifier) <= 2 do
    [name | _] = path = qualifier |> Enum.map(&String.downcase/1) |> Enum.reverse()

    with [{:table, table}] <- Map.get(bindings, name),
         1 <- Map.get(counts, name),
         {:ok, path} <- relation_path(Enum.reverse(path), table),
         [relation] <- Enum.filter(rels, &relation?(&1, path)) do
      relation
    else
      _ -> nil
    end
  end

  defp resolve(_qualifier, _sources, _rels), do: nil

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
  # Lexing: code becomes words and punctuation; literals and comments drop out
  # ---------------------------------------------------------------------------

  @lexeme ~r/[\p{L}_][\p{L}\p{N}_$]*|\d+(?:\.\d+)?(?:e[+-]?\d+)?|::|\S/iu

  defp lex(sql, profile), do: sql |> Tokenizer.tokenize(profile) |> lex_tokens()

  defp lex_tokens(tokens), do: tokens |> lex_tokens([]) |> Enum.reverse() |> Enum.concat()

  # PostgreSQL's `U&"\0073sn"` spells a name with escapes this check doesn't
  # decode, so it stands for a name that can't be compared.
  defp lex_tokens([{:code, raw}, {:identifier, _} = identifier | rest], acc) do
    if Regex.match?(~r/u&\z/i, raw),
      do: lex_tokens(rest, [[:escaped_name], lex_code(String.slice(raw, 0..-3//1)) | acc]),
      else: lex_tokens([identifier | rest], [lex_code(raw) | acc])
  end

  defp lex_tokens([token | rest], acc), do: lex_tokens(rest, [lex_token(token) | acc])
  defp lex_tokens([], acc), do: acc

  defp lex_token(token) do
    case token do
      {:code, raw} -> lex_code(raw)
      {:identifier, raw} -> [{:name, unquote_identifier(raw)}]
      {:string, _raw} -> [:lit]
      {:variable, _name, _raw} -> [:lit]
      {:block, inner} -> lex_tokens(inner)
      {:comment, _raw} -> []
    end
  end

  defp lex_code(raw) do
    @lexeme
    |> Regex.scan(raw)
    |> Enum.map(fn [lexeme] ->
      cond do
        Regex.match?(~r/^[\p{L}_]/u, lexeme) -> word(String.downcase(lexeme), lexeme)
        Regex.match?(~r/^[0-9]+$/, lexeme) -> {:int, lexeme}
        Regex.match?(~r/^\d/, lexeme) -> :lit
        true -> lexeme
      end
    end)
  end

  defp word(down, _raw) when down in @keywords, do: {:kw, down}
  defp word(_down, raw), do: {:name, raw}

  defp unquote_identifier(raw) do
    q = String.first(raw)
    raw |> String.slice(1..-2//1) |> String.replace(q <> q, q)
  end

  # ---------------------------------------------------------------------------
  # Annotation: each lexeme with its clause, and whether its names reach the
  # result
  # ---------------------------------------------------------------------------

  # Each frame is one level of parentheses: the clause its lexemes sit in
  # (:none, :with, :select, :from, :join_cond, :order, :group, :other, :table or
  # :table_order), whether the
  # names of its select list reach the result, the level it is (a number
  # for each frame, so that an ORDER BY finds its own query's output
  # columns), and whether it holds the arguments of a scalar function in
  # FROM. The names reach the result at the top level and in a derived
  # table or CTE body nested only in such frames: a consumer reads them
  # through `*` or by name, both checked where they appear. They don't in
  # an expression, a function's arguments or a WHERE subquery.
  defp annotate(lexemes) do
    lexemes = List.to_tuple(lexemes)
    size = tuple_size(lexemes)

    init = %{
      frames: [{:none, true, 0, false}],
      levels: 0,
      out: [],
      relations: MapSet.new(),
      ctes: MapSet.new(),
      outputs: MapSet.new(),
      scalar: nil,
      set_op?: false,
      alias_list?: false
    }

    state =
      Enum.reduce(0..(size - 1)//1, init, fn i, state ->
        lexeme = elem(lexemes, i)
        prev = raw_at(lexemes, i - 1)
        [{clause, reaches?, level, _scalar?} | _] = state.frames

        state
        |> note(lexeme, prev, raw_at(lexemes, i - 2), raw_at(lexemes, i + 1), clause, level)
        |> Map.update!(:out, &[{lexeme, reaches?, clause, level} | &1])
        |> step(lexeme, clause, prev)
      end)

    %{state | out: state.out |> Enum.reverse() |> List.to_tuple()}
  end

  # Relation names and aliases (in FROM) and CTE names (in WITH), so that a
  # whole-row reference to one can be found; the output columns' aliases,
  # for ORDER BY; and the renaming forms. Right after a scalar function's
  # arguments close in FROM (`state.scalar` is :call), its alias names a
  # value, not a row, and so does a column alias list after it.
  defp note(state, lexeme, prev, prev2, next, clause, level) do
    state
    |> note(lexeme, prev, prev2, next, clause)
    |> note_output(lexeme, prev, clause, level)
    |> Map.put(:scalar, scalar_after(state.scalar, lexeme, clause))
  end

  defp note(%{scalar: :call} = state, {:name, _}, _prev, _prev2, _next, :from), do: state

  defp note(%{scalar: {:alias, alias}} = state, "(", alias, _prev2, _next, :from), do: state

  defp note(state, {:name, name}, _prev, _prev2, next, :from) when next != ".",
    do: %{state | relations: MapSet.put(state.relations, String.downcase(name))}

  defp note(state, "(", prev, prev2, _next, :from) do
    if prev in [{:kw, "as"}, ")"] or (name?(prev) and alias_position?(prev2)),
      do: %{state | alias_list?: true},
      else: state
  end

  defp note(state, {:name, name}, prev, _prev2, next, :with)
       when prev in [{:kw, "with"}, {:kw, "recursive"}, ","] do
    name = String.downcase(name)

    %{state | relations: MapSet.put(state.relations, name), ctes: MapSet.put(state.ctes, name)}
    |> Map.update!(:alias_list?, &(&1 or next == "("))
  end

  defp note(state, {:kw, op}, _prev, _prev2, _next, _clause) when op in @set_ops,
    do: %{state | set_op?: true}

  defp note(state, _lexeme, _prev, _prev2, _next, _clause), do: state

  defp note_output(state, {:name, name}, {:kw, "as"}, :select, level),
    do: %{state | outputs: MapSet.put(state.outputs, {level, String.downcase(name)})}

  defp note_output(state, _lexeme, _prev, _clause, _level), do: state

  # After a scalar function's arguments close in FROM: an optional AS, then
  # its alias, then perhaps the alias's column list.
  defp scalar_after(:call, {:kw, "as"}, :from), do: :call
  defp scalar_after(:call, {:name, _} = alias, :from), do: {:alias, alias}
  defp scalar_after(_scalar, _lexeme, _clause), do: nil

  # A name follows a table or subquery here, so a "(" after it opens a column
  # alias list rather than a function's arguments.
  defp alias_position?(lexeme), do: name?(lexeme) or lexeme in [")", {:kw, "as"}]

  defp name?({:name, _}), do: true
  defp name?(_), do: false

  defp step(%{frames: [{_, reaches?, _, _} | _]} = state, "(", clause, prev) do
    level = state.levels + 1
    scalar? = clause == :from and scalar_function?(prev)
    frame = {:none, reaches? and clause in [:from, :with], level, scalar?}
    %{state | frames: [frame | state.frames], levels: level}
  end

  defp step(%{frames: [_]} = state, ")", _clause, _prev), do: state

  defp step(%{frames: [{_, _, _, scalar?} | rest]} = state, ")", _clause, _prev),
    do: %{state | frames: rest, scalar: if(scalar?, do: :call)}

  defp step(state, {:kw, "select"}, _clause, _prev), do: set_clause(state, :select)

  defp step(state, {:kw, "with"}, clause, _prev) when clause in [:none, :table, :table_order],
    do: set_clause(state, :with)

  defp step(state, {:kw, "from"}, :select, _prev), do: set_clause(state, :from)

  # `TABLE t` reads as `SELECT * FROM t ...`, so its ORDER BY sorts by the
  # table's columns, by position too. Otherwise :table and :table_order are
  # :none.
  defp step(state, {:kw, "table"}, :none, _prev), do: set_clause(state, :table)
  defp step(state, {:kw, "order"}, :table, _prev), do: set_clause(state, :table_order)

  defp step(state, {:kw, kw}, :table_order, _prev) when kw in @clause_ends and kw != "order",
    do: set_clause(state, :table)

  defp step(state, {:kw, "join"}, clause, _prev) when clause in [:from, :join_cond],
    do: set_clause(state, :from)

  defp step(state, {:kw, kw}, :from, _prev) when kw in ["on", "using"],
    do: set_clause(state, :join_cond)

  defp step(state, {:kw, "order"}, clause, _prev) when clause in @query_clauses,
    do: set_clause(state, :order)

  defp step(state, {:kw, "group"}, clause, _prev) when clause in @query_clauses,
    do: set_clause(state, :group)

  defp step(state, {:kw, kw}, clause, _prev) when kw in @clause_ends and clause in @query_clauses,
    do: set_clause(state, :other)

  defp step(state, {:kw, op}, _clause, _prev) when op in @set_ops, do: set_clause(state, :none)
  defp step(state, _lexeme, _clause, _prev), do: state

  defp scalar_function?({:name, name}), do: String.downcase(name) in @scalar_functions
  defp scalar_function?(_lexeme), do: false

  defp set_clause(%{frames: [{_, reaches?, level, scalar?} | rest]} = state, clause),
    do: %{state | frames: [{clause, reaches?, level, scalar?} | rest]}

  defp raw_at(_tuple, i) when i < 0, do: :bof
  defp raw_at(tuple, i) when i >= tuple_size(tuple), do: :eof
  defp raw_at(tuple, i), do: elem(tuple, i)

  defp at(_tuple, i) when i < 0, do: :bof
  defp at(tuple, i) when i >= tuple_size(tuple), do: :eof
  defp at(tuple, i), do: tuple |> elem(i) |> elem(0)

  # ---------------------------------------------------------------------------
  # Verification
  # ---------------------------------------------------------------------------

  defp verify(%{alias_list?: true}, _matcher, _rels) do
    {:error,
     "Query renames the columns of a table with protected columns through a column " <>
       "alias list, which Lotus can't check against column policies. Alias columns in " <>
       "the select list instead."}
  end

  defp verify(%{out: out} = state, matcher, rels) do
    sources = sources(out, state.ctes)
    protected? = &protected?(matcher, rels, &1, resolve(&2, sources, rels))
    state = Map.put(state, :safe_star?, &safe_star?(matcher, resolve(&1, sources, rels)))

    0..(tuple_size(out) - 1)//1
    |> Enum.find_value(:ok, fn i -> check_at(out, i, state, protected?) end)
  end

  # The names before `i`'s, each followed by a dot: `[schema, table]` for
  # `schema.table.column`.
  defp qualifier_at(out, i) do
    if at(out, i - 1) == "." and name?(at(out, i - 2)) do
      {:name, name} = at(out, i - 2)
      qualifier_at(out, i - 2) ++ [name]
    else
      []
    end
  end

  defp check_at(out, i, state, protected?) do
    case at(out, i) do
      {:name, name} ->
        check_name(out, i, name, state, protected?)

      "*" ->
        check_star(out, i, state)

      # `TABLE t` is `SELECT * FROM t`.
      {:kw, "table"} ->
        if state.set_op? and out |> elem(i) |> elem(2) == :none, do: set_op_error()

      {:int, n} ->
        check_position(out, i, n, state, protected?)

      :escaped_name ->
        {:error,
         "Query uses a Unicode-escaped identifier (U&\"...\"), which Lotus can't check " <>
           "against column policies. Write the name plainly."}

      _ ->
        nil
    end
  end

  defp check_name(out, i, name, state, protected?) do
    cond do
      definition?(out, i) -> nil
      protected?.(name, qualifier_at(out, i)) -> check_protected(out, i, name, state)
      whole_row?(out, i, name, state) -> whole_row_error(name)
      true -> nil
    end
  end

  # An output alias or a CTE name names something; it reads nothing.
  defp definition?(out, i) do
    prev = at(out, i - 1)
    {_lexeme, _reaches?, clause, _level} = elem(out, i)

    prev == {:kw, "as"} or
      (clause == :with and prev in [{:kw, "with"}, {:kw, "recursive"}, ","])
  end

  defp check_protected(out, i, name, state) do
    {_lexeme, reaches?, clause, _level} = elem(out, i)

    if reaches? and clause == :select and not state.set_op? and
         bare_start?(out, i) and bare_end?(out, i, name),
       do: nil,
       else: protected_error(name)
  end

  # What precedes the item, past any `schema.table.` qualifier.
  defp bare_start?(out, i) do
    if at(out, i - 1) == "." and name?(at(out, i - 2)),
      do: bare_start?(out, i - 2),
      else: at(out, i - 1) in @select_starts
  end

  defp bare_end?(out, i, name) do
    case at(out, i + 1) do
      {:kw, "as"} ->
        same_name?(at(out, i + 2), name) and at(out, i + 3) in @item_ends

      next ->
        next in @item_ends
    end
  end

  defp same_name?({:name, alias}, name), do: String.downcase(alias) == String.downcase(name)
  defp same_name?(_other, _name), do: false

  defp whole_row?(out, i, name, state) do
    {_lexeme, _reaches?, clause, _level} = elem(out, i)

    clause != :from and MapSet.member?(state.relations, String.downcase(name)) and
      at(out, i - 1) != "." and at(out, i + 1) not in [".", "("] and
      not sorts_by_output?(out, i, name, state)
  end

  # A whole ORDER BY item that names an output column of its own query sorts
  # by that column: the database reads an output name before a relation's
  # row there. Not inside an expression, where output names don't reach.
  defp sorts_by_output?(out, i, name, state) do
    {_lexeme, _reaches?, clause, level} = elem(out, i)

    clause == :order and at(out, i - 1) in [{:kw, "by"}, ","] and sort_item_end?(at(out, i + 1)) and
      MapSet.member?(state.outputs, {level, String.downcase(name)})
  end

  defp sort_item_end?({:name, word}), do: String.downcase(word) in @sort_modifiers
  defp sort_item_end?(next), do: next in @sort_item_ends

  # `count(*)` reads no column; `*` and `t.*` as select items keep the names,
  # except across a set operation; `*` between operands multiplies them.
  defp check_star(out, i, state) do
    {_lexeme, _reaches?, clause, _level} = elem(out, i)
    prev = at(out, i - 1)
    next = at(out, i + 1)

    cond do
      prev == "(" and next == ")" ->
        nil

      clause == :select and bare_start?(out, i) and next in [")" | @item_ends] ->
        if state.set_op?, do: set_op_error(), else: nil

      prev == "." ->
        whole_row_error(qualifier(at(out, i - 2)))

      true ->
        nil
    end
  end

  # A whole ORDER BY or GROUP BY item that is an integer names the select
  # item at that position, so sorting or grouping by it reveals how that
  # column's values order or repeat whatever the result shows of them. So
  # does an item of DISTINCT ON, ROLLUP, CUBE or GROUPING SETS, and one in
  # parentheses. The position must be a select item that is no protected
  # column, with no `*` up to it, whose width can't be known here.
  defp check_position(out, i, n, state, protected?) do
    with {:ok, level} <- position_level(out, i),
         {:error, message} <-
           position_item(out, level, String.to_integer(n), state.safe_star?, protected?) do
      {:error, "Query sorts or groups by position #{n}, " <> message}
    else
      _ -> nil
    end
  end

  defp position_level(out, i) do
    {_lexeme, _reaches?, clause, level} = elem(out, i)
    prev = at(out, i - 1)
    next = at(out, i + 1)

    cond do
      clause in @position_clauses and prev in [{:kw, "by"}, ","] and not operator?(next) ->
        {:ok, level}

      clause == :none and prev in ["(", ","] and next in [")", ","] ->
        out |> opening_paren(i - 1, level) |> paren_level(out)

      true ->
        nil
    end
  end

  # Punctuation that continues an expression: the integer is an operand then.
  defp operator?(next), do: is_binary(next) and next not in [",", ")", ";"]

  # The "(" that opened the frame of `level`: levels count up as frames
  # open, so it is the last lexeme before `i` of a lower level.
  defp opening_paren(_out, i, _level) when i < 0, do: nil

  defp opening_paren(out, i, level) do
    if out |> elem(i) |> elem(3) < level, do: i, else: opening_paren(out, i - 1, level)
  end

  defp paren_level(nil, _out), do: nil

  defp paren_level(j, out) do
    {_paren, _reaches?, clause, level} = elem(out, j)

    case {clause, at(out, j - 1), at(out, j - 2)} do
      {:select, {:kw, "on"}, {:kw, "distinct"}} ->
        {:ok, level}

      {clause, prev, _prev2} when clause in @position_clauses ->
        if item_start?(prev), do: {:ok, level}

      {:none, prev, _prev2} ->
        if item_start?(prev), do: out |> opening_paren(j - 1, level) |> paren_level(out)

      _ ->
        nil
    end
  end

  # What may precede a whole grouping or sort item, or a list of them.
  defp item_start?({:name, name}), do: String.downcase(name) in ~w(rollup cube sets)
  defp item_start?(prev), do: prev in [{:kw, "by"}, ",", "("]

  # Each select list of the query at `level` (a set operation has one per
  # branch): position `n` must be safe in all of them.
  defp position_item(out, level, n, safe_star?, protected?) do
    case select_lists(out, level) do
      [] -> {:error, unknown_position()}
      lists -> Enum.find_value(lists, :ok, &list_position(&1, n, safe_star?, protected?))
    end
  end

  # Up to a `*` the position is the item's. From a `t.*` over a relation
  # with no protected column (whose width isn't known here) it may be any
  # later item, so all of those must be safe.
  defp list_position(items, n, safe_star?, protected?) do
    {before, rest} = Enum.split(items, max(n - 1, 0))

    case Enum.split_while(before, &(not star_item?(&1))) do
      _ when n < 1 ->
        {:error, unknown_position()}

      {_before, []} when rest == [] ->
        {:error, unknown_position()}

      {_before, []} ->
        if star_item?(hd(rest)),
          do: items_position(rest, safe_star?, protected?),
          else: item_position(hd(rest), protected?)

      {_before, from_star} ->
        items_position(from_star ++ rest, safe_star?, protected?)
    end
  end

  defp item_position(item, protected?) do
    if name = protected_item(item, protected?), do: {:error, protected_position(name)}
  end

  defp items_position(items, safe_star?, protected?) do
    if Enum.all?(items, &safe_item?(&1, safe_star?, protected?)),
      do: nil,
      else: {:error, unknown_position()}
  end

  defp safe_item?(["*"], _safe_star?, _protected?), do: false

  defp safe_item?(item, safe_star?, protected?) do
    if star_item?(item),
      do: item |> Enum.drop(-2) |> Enum.flat_map(&name_of/1) |> safe_star?.(),
      else: protected_item(item, protected?) == nil
  end

  defp name_of({:name, name}), do: [name]
  defp name_of(_lexeme), do: []

  # The select items of each SELECT at `level`, as the lexemes of that level
  # (what nested parentheses hold is checked where it stands), without the
  # keywords that start the first item or end the list.
  defp select_lists(out, level) do
    0..(tuple_size(out) - 1)//1
    |> Enum.reduce([], fn i, lists ->
      case elem(out, i) do
        {{:kw, "select"}, _reaches?, _clause, ^level} -> [[[]] | lists]
        {",", _reaches?, :select, ^level} -> add_item(lists)
        {lexeme, _reaches?, :select, ^level} -> add_lexeme(lists, lexeme)
        _ -> lists
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn items ->
      items |> Enum.map(&Enum.reverse/1) |> Enum.reverse() |> clean_items()
    end)
  end

  defp add_item([items | lists]), do: [[[] | items] | lists]
  defp add_item([]), do: []

  defp add_lexeme([[item | items] | lists], lexeme), do: [[[lexeme | item] | items] | lists]
  defp add_lexeme([], _lexeme), do: []

  defp clean_items([first | items]) do
    first =
      case first do
        [{:kw, "distinct"}, {:kw, "on"}, "(" | rest] -> rest
        [{:kw, kw} | rest] when kw in ["distinct", "all"] -> rest
        _ -> first
      end

    Enum.map([first | items], fn item -> Enum.reject(item, &list_keyword?/1) end)
  end

  defp list_keyword?({:kw, kw}), do: kw != "as"
  defp list_keyword?(_lexeme), do: false

  # `*` or `t.*`.
  defp star_item?(["*"]), do: true
  defp star_item?([{:name, _}, "." | rest]), do: star_item?(rest)
  defp star_item?(_item), do: false

  # The first protected name the item reads (an alias after AS reads none).
  defp protected_item(item, protected?) do
    out = List.to_tuple(item)

    Enum.find_value(0..(tuple_size(out) - 1)//1, fn i ->
      case raw_at(out, i) do
        {:name, name} ->
          if raw_at(out, i - 1) != {:kw, "as"} and protected?.(name, item_qualifier(out, i)),
            do: name

        _ ->
          nil
      end
    end)
  end

  defp item_qualifier(out, i) do
    if raw_at(out, i - 1) == "." and name?(raw_at(out, i - 2)) do
      {:name, name} = raw_at(out, i - 2)
      item_qualifier(out, i - 2) ++ [name]
    else
      []
    end
  end

  defp protected_position(name) do
    "protected column #{name}, which reveals how its values order or repeat whatever " <>
      "the result shows of them. Sort or group by another column."
  end

  defp unknown_position do
    "which Lotus can't match to a select item (it follows a * or is past the select " <>
      "list), so it can't check it against column policies. Sort by the column's name."
  end

  defp qualifier({:name, name}), do: name
  defp qualifier(_), do: "*"

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

  defp set_op_error do
    {:error,
     "Query combines * with UNION, INTERSECT or EXCEPT over a table with protected " <>
       "columns, which renames them after the first branch. Select the columns by name."}
  end
end
