defmodule Lotus.Storage.VariableResolver do
  @moduledoc """
  Extracts variable-to-column bindings from SQL queries.

  Works out which table column each `{{variable}}` is compared against so
  `Lotus.Storage.Query.compile/2` can cast the value to the column's type.
  It scans `Lotus.Query.Tokenizer` tokens with a few heuristics; it is not a
  SQL parser. A variable it cannot bind falls back to the variable's declared
  type, so a miss costs nothing but a cast.

  ## Supported Patterns

  1. **Explicit**: `WHERE users.id = {{user_id}}`
  2. **Implicit**: `WHERE id = {{user_id}}` (table from the first `FROM`)
  3. **Aliased tables**: `WHERE u.id = {{id}}` (resolves alias `u` to `users`)
  4. **Schema-qualified tables**: `FROM public.users` carries `schema: "public"`
  5. **Quoted identifiers**: `"Users"."Id"` keeps its case; unquoted names
     are folded to lowercase

  A name introduced by a `WITH` clause is not a base table: a column of a
  CTE, or of an alias of one, binds with `table: nil`. So does a column of a
  subquery in `FROM`.

  ## Usage

      sql = "SELECT * FROM users WHERE users.id = {{user_id}}"
      VariableResolver.resolve_variables(sql)
      # => [%{variable: "user_id", schema: nil, table: "users", column: "id"}]
  """

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile

  @type variable_binding :: %{
          variable: String.t(),
          schema: String.t() | nil,
          table: String.t() | nil,
          column: String.t() | nil
        }

  @typep lexeme :: {:name, String.t()} | {:var, String.t()} | {:punct, String.t()}

  @punct_operators ~w(= <> != <= >= < >)
  @word_operators ~w(like ilike in)
  @not_a_column ~w(not and or)
  @not_an_alias ~w(where on join inner left right full cross outer natural group order limit
                   offset having union except intersect using set values window fetch for
                   lateral returning tablesample and or as with select)

  defguardp is_op(lexeme)
            when (elem(lexeme, 0) == :punct and elem(lexeme, 1) in @punct_operators) or
                   (elem(lexeme, 0) == :name and elem(lexeme, 1) in @word_operators)

  @doc """
  Extract variable bindings from a SQL statement.

  Returns one binding per variable, deduplicated by name. An explicit
  binding wins over an implicit one, and both win over an unbound
  occurrence. The `profile` selects the quoting and comment rules; it
  defaults to ANSI SQL.

  ## Examples

      resolve_variables("SELECT * FROM users WHERE users.id = {{user_id}}")
      # => [%{variable: "user_id", schema: nil, table: "users", column: "id"}]

      resolve_variables("SELECT * FROM users u WHERE u.id = {{user_id}}")
      # => [%{variable: "user_id", schema: nil, table: "users", column: "id"}]

      resolve_variables("SELECT * FROM public.users WHERE id = {{user_id}}")
      # => [%{variable: "user_id", schema: "public", table: "users", column: "id"}]
  """
  @spec resolve_variables(String.t(), Profile.t()) :: [variable_binding()]
  def resolve_variables(sql, %Profile{} = profile \\ Profile.for_language("sql"))
      when is_binary(sql) do
    lexemes = sql |> Tokenizer.tokenize(profile) |> lexemes(profile)
    cte_names = cte_names(lexemes)
    aliases = table_aliases(lexemes)
    primary = primary_table(lexemes, cte_names)

    explicit = explicit_bindings(lexemes, aliases, cte_names, [])
    implicit = implicit_bindings(lexemes, primary, nil, [])
    bound = Enum.map(explicit ++ implicit, & &1.variable)
    unbound = unbound_bindings(lexemes, bound, primary)

    Enum.uniq_by(explicit ++ implicit ++ unbound, & &1.variable)
  end

  # ---------------------------------------------------------------------------
  # Lexemes: code words and punctuation, quoted identifiers with their case,
  # and placeholders. Strings and comments are dropped; blocks are flattened.
  # ---------------------------------------------------------------------------

  @code_lexeme ~r/<>|<=|>=|!=|\w+|[^\w\s]/u

  @spec lexemes([Tokenizer.token()], Profile.t()) :: [lexeme()]
  defp lexemes(tokens, profile) do
    Enum.flat_map(tokens, fn
      {:code, raw} -> code_lexemes(raw)
      {:identifier, raw} -> [{:name, unquote_identifier(raw)}]
      {:variable, name, _raw} -> [{:var, name}]
      {:block, inner} -> lexemes(inner, profile)
      _token -> []
    end)
  end

  defp code_lexemes(raw) do
    @code_lexeme
    |> Regex.scan(raw)
    |> Enum.map(fn [piece] ->
      if Regex.match?(~r/\A\w+\z/u, piece),
        do: {:name, String.downcase(piece)},
        else: {:punct, piece}
    end)
  end

  defp unquote_identifier(raw) do
    quote = String.first(raw)
    inner = raw |> String.trim_leading(quote) |> String.trim_trailing(quote)
    String.replace(inner, quote <> quote, quote)
  end

  # ---------------------------------------------------------------------------
  # Table references, aliases and CTE names
  # ---------------------------------------------------------------------------

  defp table_ref([{:name, schema}, {:punct, "."}, {:name, table} | rest])
       when schema not in @not_an_alias do
    {:ok, {schema, table}, rest}
  end

  defp table_ref([{:name, table} | rest]) when table not in @not_an_alias do
    {:ok, {nil, table}, rest}
  end

  defp table_ref(_lexemes), do: :error

  defp alias_of([{:name, "as"}, {:name, name} | _rest]), do: name
  defp alias_of([{:name, name} | _rest]) when name not in @not_an_alias, do: name
  defp alias_of(_lexemes), do: nil

  defp table_aliases(lexemes) do
    table_aliases(lexemes, %{})
  end

  defp table_aliases([{:name, keyword} | rest], acc) when keyword in ["from", "join"] do
    case table_ref(rest) do
      {:ok, {_schema, table} = ref, after_ref} ->
        acc = Map.put_new(acc, table, ref)

        case alias_of(after_ref) do
          nil -> table_aliases(after_ref, acc)
          name -> table_aliases(after_ref, Map.put(acc, name, ref))
        end

      :error ->
        table_aliases(rest, acc)
    end
  end

  defp table_aliases([_lexeme | rest], acc), do: table_aliases(rest, acc)
  defp table_aliases([], acc), do: acc

  defp cte_names([{:name, "with"}, {:name, "recursive"} | rest]), do: collect_cte_names(rest, [])
  defp cte_names([{:name, "with"} | rest]), do: collect_cte_names(rest, [])
  defp cte_names(_lexemes), do: []

  defp collect_cte_names([{:name, name} | rest], acc) do
    rest = skip_group(rest)

    case rest do
      [{:name, "as"} | rest] ->
        rest = rest |> skip_materialized() |> skip_group()

        case rest do
          [{:punct, ","} | rest] -> collect_cte_names(rest, [name | acc])
          _ -> [name | acc]
        end

      _ ->
        acc
    end
  end

  defp collect_cte_names(_lexemes, acc), do: acc

  defp skip_materialized([{:name, "not"}, {:name, "materialized"} | rest]), do: rest
  defp skip_materialized([{:name, "materialized"} | rest]), do: rest
  defp skip_materialized(rest), do: rest

  defp skip_group([{:punct, "("} | rest]), do: skip_group(rest, 1)
  defp skip_group(rest), do: rest

  defp skip_group(rest, 0), do: rest
  defp skip_group([], _depth), do: []
  defp skip_group([{:punct, "("} | rest], depth), do: skip_group(rest, depth + 1)
  defp skip_group([{:punct, ")"} | rest], depth), do: skip_group(rest, depth - 1)
  defp skip_group([_lexeme | rest], depth), do: skip_group(rest, depth)

  # The first top-level FROM names the table implicit bindings belong to.
  # A subquery or a CTE there leaves the table unknown.
  defp primary_table(lexemes, cte_names), do: primary_table(lexemes, cte_names, 0)

  defp primary_table([{:name, "from"} | rest], cte_names, 0) do
    case table_ref(rest) do
      {:ok, ref, _rest} -> base_table(ref, cte_names)
      :error -> nil
    end
  end

  defp primary_table([{:punct, "("} | rest], cte_names, depth),
    do: primary_table(rest, cte_names, depth + 1)

  defp primary_table([{:punct, ")"} | rest], cte_names, depth),
    do: primary_table(rest, cte_names, max(depth - 1, 0))

  defp primary_table([_lexeme | rest], cte_names, depth),
    do: primary_table(rest, cte_names, depth)

  defp primary_table([], _cte_names, _depth), do: nil

  defp base_table({_schema, table} = ref, cte_names) do
    if table in cte_names, do: nil, else: ref
  end

  # ---------------------------------------------------------------------------
  # Bindings
  # ---------------------------------------------------------------------------

  defp explicit_bindings(
         [
           {:name, schema},
           {:punct, "."},
           {:name, table},
           {:punct, "."},
           {:name, column},
           op,
           {:var, var} | rest
         ],
         aliases,
         cte_names,
         acc
       )
       when is_op(op) do
    binding = binding(var, base_table({schema, table}, cte_names), column)
    explicit_bindings(rest, aliases, cte_names, [binding | acc])
  end

  defp explicit_bindings(
         [{:name, qualifier}, {:punct, "."}, {:name, column}, op, {:var, var} | rest],
         aliases,
         cte_names,
         acc
       )
       when is_op(op) do
    ref = Map.get(aliases, qualifier, {nil, qualifier})
    binding = binding(var, base_table(ref, cte_names), column)
    explicit_bindings(rest, aliases, cte_names, [binding | acc])
  end

  defp explicit_bindings([_lexeme | rest], aliases, cte_names, acc),
    do: explicit_bindings(rest, aliases, cte_names, acc)

  defp explicit_bindings([], _aliases, _cte_names, acc), do: Enum.reverse(acc)

  defp implicit_bindings([{:name, column} = lexeme, op, {:var, var} | rest], primary, prev, acc)
       when is_op(op) and prev != {:punct, "."} and column not in @not_a_column do
    implicit_bindings(rest, primary, lexeme, [binding(var, primary, column) | acc])
  end

  defp implicit_bindings([lexeme | rest], primary, _prev, acc),
    do: implicit_bindings(rest, primary, lexeme, acc)

  defp implicit_bindings([], _primary, _prev, acc), do: Enum.reverse(acc)

  defp unbound_bindings(lexemes, bound, primary) do
    lexemes
    |> Enum.flat_map(fn
      {:var, var} -> [var]
      _lexeme -> []
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in bound))
    |> Enum.map(&binding(&1, primary, nil))
  end

  defp binding(var, nil, column), do: %{variable: var, schema: nil, table: nil, column: column}

  defp binding(var, {schema, table}, column),
    do: %{variable: var, schema: schema, table: table, column: column}
end
