defmodule Lotus.Source.Adapters.Ecto.Dialects.MySQL.Relations do
  @moduledoc false

  # The tables a MySQL statement reads, from its text, for the visibility
  # check. `EXPLAIN FORMAT=JSON` names a table by its alias and without its
  # schema, so the MySQL dialect reads the statement too, takes the union of
  # both, and maps each name EXPLAIN gives back to the tables it can stand
  # for (`resolve/2`).
  #
  # The statement is read through `Lotus.Query.Tokenizer` under the MySQL
  # profile, so a `FROM` in a string, a quoted name or a comment is not
  # code. It errs toward reading too much: every item of every FROM list
  # (comma-separated or joined, inside parentheses or not), in the outer
  # query, in subqueries anywhere (FROM, WHERE, IN, EXISTS, the select
  # list) and in CTEs. A FROM inside a function's parentheses
  # (`EXTRACT(YEAR FROM d)`, `TRIM(x FROM s)`) names no table. A name that
  # a WITH clause defines is not a table, nor is an alias of one, nor is
  # `DUAL`.

  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Source.Adapters.Ecto, as: EctoHelpers

  @type relation :: {String.t() | nil, String.t()}

  @type t :: %__MODULE__{
          tables: [relation()],
          names: %{String.t() => [relation()]},
          not_tables: %{String.t() => true},
          ctes: %{String.t() => true}
        }

  defstruct tables: [], names: %{}, not_tables: %{}, ctes: %{}

  # Words that end a FROM clause.
  @ends ~w(where group having order limit union except intersect window for into lock
           procedure)

  @joins ~w(join straight_join)

  # Words after a table that are not its alias.
  @not_alias @ends ++
               @joins ++
               ~w(on using left right inner outer cross natural use ignore force partition
                  lateral as)

  @doc """
  Reads the tables of `sql`: `tables` in order of first appearance, `names`
  from each table name and alias to the tables it stands for, `not_tables`
  the aliases of derived tables and table functions, and `ctes` the names
  WITH clauses define.
  """
  @spec read(String.t()) :: t()
  def read(sql) when is_binary(sql) do
    acc =
      sql
      |> EctoHelpers.sql_lexemes(Profile.for_language("sql:mysql"))
      |> walk([true], %__MODULE__{})

    cte? = fn {schema, table} -> is_nil(schema) and Map.has_key?(acc.ctes, table) end
    tables = acc.tables |> Enum.reverse() |> Enum.reject(cte?) |> Enum.uniq()
    names = Map.new(acc.names, fn {name, relations} -> {name, Enum.reject(relations, cte?)} end)

    %{acc | tables: tables, names: names}
  end

  @doc """
  The tables a relation from EXPLAIN stands for. An alias or a table name
  the statement reads maps to its table(s), with the schema the statement
  gave; a derived table, a table function's alias, a CTE and MySQL's
  internal `<derived2>`/`<union1,2>` map to nothing, since the tables they
  read are listed on their own; any other name is kept as it is.
  """
  @spec resolve(relation(), t()) :: [relation()]
  def resolve({schema, name}, %__MODULE__{} = read) do
    cond do
      Map.has_key?(read.names, name) -> Map.fetch!(read.names, name)
      String.starts_with?(name, "<") -> []
      Map.has_key?(read.not_tables, name) -> []
      Map.has_key?(read.ctes, name) -> []
      true -> [{schema, name}]
    end
  end

  # ---------------------------------------------------------------------------
  # The whole statement: a FROM or WITH where a query can be, which is the
  # top level or a parenthesis that opens a query.
  # ---------------------------------------------------------------------------

  defp walk([], _stack, acc), do: acc

  defp walk([{:punct, "("} | rest], stack, acc),
    do: walk(rest, [query_start?(rest) | stack], acc)

  defp walk([{:punct, ")"} | rest], [_top | [_ | _] = stack], acc), do: walk(rest, stack, acc)
  defp walk([{:punct, ")"} | rest], stack, acc), do: walk(rest, stack, acc)

  defp walk([{:word, word} | rest], [true | _] = stack, acc) do
    acc =
      case String.downcase(word) do
        "from" -> from_list(rest, true, acc)
        "with" -> ctes(rest, acc)
        _ -> acc
      end

    walk(rest, stack, acc)
  end

  defp walk([_lexeme | rest], stack, acc), do: walk(rest, stack, acc)

  defp query_start?([{:word, word} | _rest]),
    do: String.downcase(word) in ~w(select with table values)

  defp query_start?([{:punct, "("} | _rest]), do: true
  defp query_start?(_lexemes), do: false

  # ---------------------------------------------------------------------------
  # A FROM list: table references separated by commas and joins, until the
  # clause ends. `expect?` says a table reference comes next. Subqueries are
  # skipped here; `walk/3` reads them.
  # ---------------------------------------------------------------------------

  defp from_list([], _expect?, acc), do: acc
  defp from_list([{:punct, ")"} | _rest], _expect?, acc), do: acc
  defp from_list([{:punct, ";"} | _rest], _expect?, acc), do: acc
  defp from_list([{:punct, ","} | rest], _expect?, acc), do: from_list(rest, true, acc)

  defp from_list([{:punct, "("} | rest], true, acc) do
    {inner, after_group} = split_group(rest)

    if query_start?(inner) do
      # A derived table: its alias is not a table.
      {alias_name, rest} = alias_of(after_group)
      from_list(rest, false, add_not_table(acc, alias_name))
    else
      # Parenthesized table references: `FROM (t1, t2 JOIN t3 ON ...)`.
      from_list(after_group, false, from_list(inner, true, acc))
    end
  end

  defp from_list([{:punct, "("} | rest], false, acc) do
    {_inner, after_group} = split_group(rest)
    from_list(after_group, false, acc)
  end

  defp from_list([{:word, word} | rest] = lexemes, expect?, acc) do
    keyword = String.downcase(word)

    cond do
      keyword in @ends -> acc
      keyword in @joins -> from_list(rest, true, acc)
      expect? and keyword == "lateral" -> from_list(rest, true, acc)
      expect? -> table_reference(lexemes, acc)
      true -> from_list(rest, false, acc)
    end
  end

  defp from_list([{:identifier, _raw} | _rest] = lexemes, true, acc),
    do: table_reference(lexemes, acc)

  defp from_list([_lexeme | rest], expect?, acc), do: from_list(rest, expect?, acc)

  defp table_reference([name, {:punct, "("} | rest], acc) do
    # A table function (`JSON_TABLE(...) AS jt`): its alias is not a table.
    {_inner, after_group} = split_group(rest)

    case name_of(name) do
      {:ok, _function} ->
        {alias_name, rest} = alias_of(after_group)
        from_list(rest, false, add_not_table(acc, alias_name))

      :error ->
        from_list(after_group, false, acc)
    end
  end

  defp table_reference([schema, {:punct, "."}, table | rest], acc) do
    with {:ok, schema} <- name_of(schema), {:ok, table} <- name_of(table) do
      {alias_name, rest} = alias_of(rest)
      from_list(rest, false, add_table(acc, {schema, table}, alias_name))
    else
      _ -> from_list(rest, false, acc)
    end
  end

  defp table_reference([table | rest], acc) do
    case name_of(table) do
      {:ok, name} ->
        {alias_name, rest} = alias_of(rest)

        if String.downcase(name) == "dual" and match?({:word, _}, table),
          do: from_list(rest, false, acc),
          else: from_list(rest, false, add_table(acc, {nil, name}, alias_name))

      :error ->
        from_list(rest, false, acc)
    end
  end

  defp alias_of([{:word, as}, name | rest] = lexemes) do
    with "as" <- String.downcase(as), {:ok, alias_name} <- name_of(name) do
      {alias_name, rest}
    else
      _ -> bare_alias(lexemes)
    end
  end

  defp alias_of(lexemes), do: bare_alias(lexemes)

  defp bare_alias([{:word, word} | rest] = lexemes) do
    if String.downcase(word) in @not_alias, do: {nil, lexemes}, else: {word, rest}
  end

  defp bare_alias([{:identifier, raw} | rest]), do: {EctoHelpers.unquote_identifier(raw), rest}
  defp bare_alias(lexemes), do: {nil, lexemes}

  defp name_of({:identifier, raw}), do: {:ok, EctoHelpers.unquote_identifier(raw)}

  defp name_of({:word, word}) do
    if word =~ ~r/\A[0-9]+\z/, do: :error, else: {:ok, word}
  end

  defp name_of(_lexeme), do: :error

  defp add_table(acc, {_schema, table} = relation, alias_name) do
    names =
      [table, alias_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(acc.names, fn name, names ->
        Map.update(names, name, [relation], &Enum.uniq(&1 ++ [relation]))
      end)

    %{acc | tables: [relation | acc.tables], names: names}
  end

  defp add_not_table(acc, nil), do: acc
  defp add_not_table(acc, name), do: %{acc | not_tables: Map.put(acc.not_tables, name, true)}

  # ---------------------------------------------------------------------------
  # WITH [RECURSIVE] name [(columns)] AS (...) [, ...]: the names it defines.
  # `GROUP BY x WITH ROLLUP` defines none.
  # ---------------------------------------------------------------------------

  defp ctes([{:word, word} | rest] = lexemes, acc) do
    if String.downcase(word) == "recursive", do: cte_list(rest, acc), else: cte_list(lexemes, acc)
  end

  defp ctes(_lexemes, acc), do: acc

  defp cte_list([name | rest], acc) do
    rest =
      case rest do
        [{:punct, "("} | columns] -> columns |> split_group() |> elem(1)
        _ -> rest
      end

    with {:ok, name} <- name_of(name),
         [{:word, as}, {:punct, "("} | body] <- rest,
         "as" <- String.downcase(as) do
      acc = %{acc | ctes: Map.put(acc.ctes, name, true)}

      case split_group(body) do
        {_body, [{:punct, ","} | more]} -> cte_list(more, acc)
        _ -> acc
      end
    else
      _ -> acc
    end
  end

  defp cte_list([], acc), do: acc

  # The lexemes up to the `)` that closes an open parenthesis, and those
  # after it.
  defp split_group(lexemes), do: split_group(lexemes, 1, [])

  defp split_group([], _depth, inner), do: {Enum.reverse(inner), []}
  defp split_group([{:punct, ")"} | rest], 1, inner), do: {Enum.reverse(inner), rest}

  defp split_group([{:punct, ")"} = lexeme | rest], depth, inner),
    do: split_group(rest, depth - 1, [lexeme | inner])

  defp split_group([{:punct, "("} = lexeme | rest], depth, inner),
    do: split_group(rest, depth + 1, [lexeme | inner])

  defp split_group([lexeme | rest], depth, inner), do: split_group(rest, depth, [lexeme | inner])
end
