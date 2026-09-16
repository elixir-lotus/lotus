defmodule Lotus.Visibility.Matcher do
  @moduledoc """
  The compiled form of a visibility rule set.

  `Lotus.Visibility.compile/2` turns the schema, table and column rules a
  resolver returns into one of these, once. Exact names go into sets, regex
  rules into short ordered lists, and the built-in denies of the source's
  adapter are merged into the deny sets. Every check in `Lotus.Visibility`
  then runs against the compiled form instead of walking the raw rules.

  The struct is opaque to callers. Build it with `Lotus.Visibility.compile/2`
  and pass it to the `Lotus.Visibility` check functions. Precedence and
  matching are exactly those documented in `Lotus.Visibility`.
  """

  alias Lotus.Visibility.Policy

  @type name_set :: %{exact: MapSet.t(String.t()), patterns: [Regex.t()]}

  @type table_set :: %{
          exact: MapSet.t({String.t() | nil, String.t()}),
          bare: MapSet.t(String.t()),
          patterns: [{term(), term()}]
        }

  @type table_allow ::
          :all
          | %{
              applies_to_all?: boolean(),
              schemas: name_set(),
              nil_schema?: boolean(),
              rules: table_set()
            }

  @type column_rules :: %{
          schema_table: [{term(), term(), term(), term()}],
          table: [{term(), term(), term()}],
          exact: %{String.t() => {non_neg_integer(), term()}},
          patterns: [{non_neg_integer(), term(), term()}]
        }

  @type t :: %__MODULE__{
          schema_allow: :all | name_set(),
          schema_deny: name_set(),
          table_allow: table_allow(),
          table_deny: table_set(),
          column: column_rules()
        }

  @empty_names %{exact: MapSet.new(), patterns: []}
  @empty_tables %{exact: MapSet.new(), bare: MapSet.new(), patterns: []}
  @empty_columns %{schema_table: [], table: [], exact: %{}, patterns: []}

  defstruct schema_allow: :all,
            schema_deny: @empty_names,
            table_allow: :all,
            table_deny: @empty_tables,
            column: @empty_columns

  # ---------------------------------------------------------------------------
  # Compilation
  # ---------------------------------------------------------------------------

  @doc false
  @spec compile(map()) :: t()
  def compile(%{} = rules) do
    schema = Map.get(rules, :schema) || []
    table = Map.get(rules, :table) || []
    column = Map.get(rules, :column) || []

    %__MODULE__{
      schema_allow: compile_schema_allow(schema[:allow]),
      schema_deny: compile_names(schema[:deny]),
      table_allow: compile_table_allow(table[:allow]),
      table_deny: compile_tables(table[:deny]),
      column: compile_columns(column)
    }
  end

  @doc false
  @spec merge_builtin(t(), [term()], [term()]) :: t()
  def merge_builtin(%__MODULE__{} = matcher, [], []), do: matcher

  def merge_builtin(%__MODULE__{} = matcher, schema_denies, table_denies) do
    %{
      matcher
      | schema_deny: merge_names(matcher.schema_deny, compile_names(schema_denies)),
        table_deny: merge_tables(matcher.table_deny, compile_tables(table_denies))
    }
  end

  defp compile_schema_allow(allow) when allow in [nil, [], :all], do: :all
  defp compile_schema_allow(allow), do: compile_names(allow)

  defp compile_names(nil), do: @empty_names

  defp compile_names(rules) do
    Enum.reduce(rules, @empty_names, fn
      %Regex{} = rx, acc -> %{acc | patterns: [rx | acc.patterns]}
      name, acc when is_binary(name) -> %{acc | exact: MapSet.put(acc.exact, name)}
      _other, acc -> acc
    end)
    |> reverse_patterns()
  end

  defp compile_table_allow(allow) when allow in [nil, []], do: :all

  defp compile_table_allow(rules) do
    init = %{
      applies_to_all?: false,
      schemas: @empty_names,
      nil_schema?: false,
      rules: @empty_tables
    }

    Enum.reduce(rules, init, fn
      {schema_pat, _table_pat} = rule, acc ->
        acc
        |> note_allow_schema(schema_pat)
        |> Map.update!(:rules, &add_table_rule(&1, rule))

      table, acc when is_binary(table) ->
        %{acc | applies_to_all?: true, rules: add_table_rule(acc.rules, table)}

      _other, acc ->
        %{acc | applies_to_all?: true}
    end)
    |> Map.update!(:schemas, &reverse_patterns/1)
    |> Map.update!(:rules, &reverse_patterns/1)
  end

  defp note_allow_schema(acc, nil), do: %{acc | nil_schema?: true}

  defp note_allow_schema(acc, schema) when is_binary(schema),
    do: put_in(acc, [:schemas, :exact], MapSet.put(acc.schemas.exact, schema))

  defp note_allow_schema(acc, %Regex{} = rx),
    do: put_in(acc, [:schemas, :patterns], [rx | acc.schemas.patterns])

  defp note_allow_schema(acc, _other), do: %{acc | applies_to_all?: true}

  defp compile_tables(nil), do: @empty_tables

  defp compile_tables(rules) do
    rules
    |> Enum.reduce(@empty_tables, &add_table_rule(&2, &1))
    |> reverse_patterns()
  end

  defp add_table_rule(set, {schema, table})
       when (is_binary(schema) or is_nil(schema)) and is_binary(table),
       do: %{set | exact: MapSet.put(set.exact, {schema, table})}

  defp add_table_rule(set, {_schema, _table} = rule),
    do: %{set | patterns: [rule | set.patterns]}

  defp add_table_rule(set, table) when is_binary(table),
    do: %{set | bare: MapSet.put(set.bare, table)}

  defp add_table_rule(set, _other), do: set

  defp compile_columns(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce(@empty_columns, fn
      {{_schema, _table, _column, _policy} = rule, _pos}, acc ->
        %{acc | schema_table: [rule | acc.schema_table]}

      {{_table, _column, _policy} = rule, _pos}, acc ->
        %{acc | table: [rule | acc.table]}

      {{column, policy}, pos}, acc when is_binary(column) and column != "*" ->
        %{acc | exact: Map.put_new(acc.exact, column, {pos, policy})}

      {{column, policy}, pos}, acc ->
        %{acc | patterns: [{pos, column, policy} | acc.patterns]}

      _other, acc ->
        acc
    end)
    |> Map.update!(:schema_table, &Enum.reverse/1)
    |> Map.update!(:table, &Enum.reverse/1)
    |> reverse_patterns()
  end

  defp reverse_patterns(%{patterns: patterns} = set),
    do: %{set | patterns: Enum.reverse(patterns)}

  defp merge_names(a, b),
    do: %{exact: MapSet.union(a.exact, b.exact), patterns: a.patterns ++ b.patterns}

  defp merge_tables(a, b) do
    %{
      exact: MapSet.union(a.exact, b.exact),
      bare: MapSet.union(a.bare, b.bare),
      patterns: a.patterns ++ b.patterns
    }
  end

  # ---------------------------------------------------------------------------
  # Matching
  # ---------------------------------------------------------------------------

  @doc false
  @spec allowed_schema?(t(), String.t() | nil) :: boolean()
  def allowed_schema?(%__MODULE__{} = matcher, schema) do
    schema_allow_pass?(matcher.schema_allow, schema) and
      not name_match?(matcher.schema_deny, schema)
  end

  @doc false
  @spec allowed_relation?(t(), {String.t() | nil, String.t()}) :: boolean()
  def allowed_relation?(%__MODULE__{} = matcher, {schema, table}) do
    allowed_schema?(matcher, schema) and
      table_allow_pass?(matcher.table_allow, schema, table) and
      not table_match?(matcher.table_deny, schema, table)
  end

  @doc false
  @spec column_policy(t(), [{String.t() | nil, String.t()}] | nil, String.t()) :: term() | nil
  def column_policy(%__MODULE__{column: column}, relations, column_name) do
    rels = relations || []

    find_schema_table_column(column.schema_table, rels, column_name) ||
      find_table_column(column.table, rels, column_name) ||
      find_column(column, column_name)
  end

  defp schema_allow_pass?(:all, _schema), do: true
  defp schema_allow_pass?(set, schema), do: name_match?(set, schema)

  defp name_match?(set, name) do
    MapSet.member?(set.exact, name) or
      (is_binary(name) and Enum.any?(set.patterns, &Regex.match?(&1, name)))
  end

  defp table_allow_pass?(:all, _schema, _table), do: true

  defp table_allow_pass?(allow, schema, table) do
    not allow_applies?(allow, schema) or table_match?(allow.rules, schema, table)
  end

  defp allow_applies?(allow, schema) do
    allow.applies_to_all? or
      (allow.nil_schema? and schema in [nil, ""]) or
      name_match?(allow.schemas, schema)
  end

  defp table_match?(set, schema, table) do
    MapSet.member?(set.exact, {schema, table}) or
      (schema == "" and MapSet.member?(set.exact, {nil, table})) or
      MapSet.member?(set.bare, table) or
      Enum.any?(set.patterns, fn {schema_pat, table_pat} ->
        pattern_match?(schema_pat, schema) and pattern_match?(table_pat, table)
      end)
  end

  # Only a `nil` schema pattern matches a relation without a schema, so a
  # rule written for SQLite never matches a Postgres relation.
  defp pattern_match?(%Regex{} = rx, val) when is_binary(val), do: Regex.match?(rx, val)
  defp pattern_match?(%Regex{}, nil), do: false
  defp pattern_match?(str, val) when is_binary(str) and is_binary(val), do: str == val
  defp pattern_match?(nil, s) when s in [nil, ""], do: true
  defp pattern_match?(nil, _), do: false
  defp pattern_match?(_, _), do: false

  defp find_schema_table_column(_rules, [], _column_name), do: nil

  defp find_schema_table_column(rules, rels, column_name) do
    Enum.find_value(rules, fn {schema_pat, table_pat, col_pat, policy} ->
      if Enum.any?(rels, fn {s, t} ->
           cv_match?(schema_pat, s) and cv_match?(table_pat, t) and
             cv_match?(col_pat, column_name)
         end),
         do: normalize(policy)
    end)
  end

  defp find_table_column(_rules, [], _column_name), do: nil

  defp find_table_column(rules, rels, column_name) do
    Enum.find_value(rules, fn {table_pat, col_pat, policy} ->
      if Enum.any?(rels, fn {_s, t} ->
           cv_match?(table_pat, t) and cv_match?(col_pat, column_name)
         end),
         do: normalize(policy)
    end)
  end

  defp find_column(column, column_name) do
    exact = Map.get(column.exact, column_name)

    pattern =
      Enum.find(column.patterns, fn {_pos, col_pat, _policy} ->
        cv_match?(col_pat, column_name)
      end)

    case {exact, pattern} do
      {nil, nil} ->
        nil

      {{_pos, policy}, nil} ->
        normalize(policy)

      {nil, {_pos, _pat, policy}} ->
        normalize(policy)

      {{exact_pos, policy}, {pattern_pos, _pat, _}} when exact_pos < pattern_pos ->
        normalize(policy)

      {_exact, {_pos, _pat, policy}} ->
        normalize(policy)
    end
  end

  defp cv_match?(%Regex{} = rx, val) when is_binary(val), do: Regex.match?(rx, val)
  defp cv_match?(%Regex{}, _), do: false
  defp cv_match?("*", _), do: true
  defp cv_match?(str, val) when is_binary(str) and is_binary(val), do: str == val
  defp cv_match?(nil, s) when s in [nil, ""], do: true
  defp cv_match?(_, _), do: false

  defp normalize(policy), do: Policy.normalize_column_policy(policy)
end
