defmodule Lotus.Preflight do
  @moduledoc """
  Statement preflight authorization for Lotus.

  Delegates to the adapter's `extract_accessed_resources/2` callback to
  discover which tables/relations a statement will access, then checks
  those relations against visibility rules before execution.

  This provides defense-in-depth by blocking queries that would access
  denied tables, even if they're accessed through views or complex subqueries.

  When an adapter returns `{:unrestricted, reason}` the statement is allowed
  through only if the host application has opted in via
  `config :lotus, :allow_unrestricted_resources`; otherwise preflight returns
  an error. The opted-in case records `{:unrestricted, reason}` rather than a
  relation list, so a later consumer can tell "touches no table" apart from
  "this adapter cannot name its tables".
  """

  alias Lotus.Config
  alias Lotus.Preflight.{Columns, Relations}
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Visibility
  alias Lotus.Visibility.Matcher

  @doc """
  Authorizes a statement by checking all relations it would access.

  Delegates resource extraction to the adapter, then validates each
  relation against the visibility rules.

  `scope` is the opaque caller-supplied value handed to the visibility
  resolver, the same one `Lotus.list_tables/2` and friends accept. Pass it
  and a per-scope deny blocks execution; omit it and only the unscoped
  rules apply. Without it a resolver that hides a table from one tenant
  would hide it in the explorer while the query still returned its rows.
  """
  @spec authorize(Adapter.t(), Statement.t(), String.t() | nil, term()) ::
          :ok | {:error, String.t()}
  def authorize(%Adapter{} = adapter, %Statement{} = statement, search_path \\ nil, scope \\ nil) do
    with {:ok, _relations} <- analyze(adapter, statement, search_path, scope), do: :ok
  end

  @doc """
  Authorizes a statement and returns what preflight learned about it.

  The same check as `authorize/4`, returning the outcome as a value: the list
  of `{schema, table}` relations the statement touches — empty when it touches
  none — or `{:unrestricted, reason}` when the adapter cannot name them and the
  host opted in. `Lotus.Runner` carries this value down the pipeline and into
  the `:before_execute` and `:after_query` payloads.
  """
  @spec analyze(Adapter.t(), Statement.t(), String.t() | nil, term()) ::
          {:ok, Relations.outcome()} | {:error, String.t()}
  def analyze(%Adapter{} = adapter, %Statement{} = statement, search_path \\ nil, scope \\ nil),
    do:
      do_analyze(adapter, statement, search_path, fn ->
        Visibility.matcher_for(adapter.name, scope)
      end)

  @doc false
  # `analyze/4` with the caller's compiled matcher, so that a caller that
  # needs it for further checks asks the resolver once.
  @spec analyze_with(Adapter.t(), Statement.t(), String.t() | nil, Matcher.t()) ::
          {:ok, Relations.outcome()} | {:error, String.t()}
  def analyze_with(
        %Adapter{} = adapter,
        %Statement{} = statement,
        search_path,
        %Matcher{} = matcher
      ),
      do: do_analyze(adapter, statement, search_path, fn -> matcher end)

  defp do_analyze(adapter, statement, search_path, matcher_fun) do
    statement =
      if search_path,
        do: %{statement | meta: Map.put(statement.meta, :search_path, search_path)},
        else: statement

    case extract_accessed_resources(adapter, statement) do
      {:ok, relations} ->
        rels = MapSet.to_list(relations)
        check_relations_visibility(rels, matcher_fun)

      {:error, e} ->
        with :ok <- named_relations_visible(adapter, statement, search_path, matcher_fun),
             do: {:error, normalize_preflight_error(e, adapter)}

      {:unrestricted, reason} ->
        handle_unrestricted(adapter, reason)
    end
  end

  # A source that raises while it plans the statement (a bound value it
  # can't encode for the column's type) fails it as one that returns an
  # error does: after the tables the statement names are checked.
  defp extract_accessed_resources(adapter, statement) do
    Adapter.extract_accessed_resources(adapter, statement)
  rescue
    e -> {:error, e}
  end

  defp handle_unrestricted(%Adapter{name: name}, reason) do
    if Config.allow_unrestricted_resources?(name) do
      {:ok, {:unrestricted, reason}}
    else
      {:error,
       "Preflight blocked: source #{inspect(name)} cannot enforce visibility at the " <>
         "adapter layer (#{reason}). Set `config :lotus, :allow_unrestricted_resources, true` " <>
         "or opt in per-source via `allow_unrestricted_resources: true` in the source's " <>
         "data_sources entry."}
    end
  end

  defp check_relations_visibility([], _matcher_fun), do: {:ok, []}

  defp check_relations_visibility(rels, matcher_fun) do
    matcher = matcher_fun.()
    {allowed, blocked} = Enum.split_with(rels, &Visibility.allowed_relation?(matcher, &1))

    if blocked == [] do
      {:ok, allowed}
    else
      {:error, "Query touches blocked table(s): #{format_relations(blocked)}"}
    end
  end

  # The source's error for a statement it couldn't plan can tell whether a
  # hidden table has a column (`no such column`), which a refusal does not.
  # So the tables the statement names count first: one the rules hide under
  # every schema it could resolve to gets the refusal a planned statement
  # would. An unquoted name may fold to lower case, so either spelling hides.
  defp named_relations_visible(adapter, %Statement{body: sql}, search_path, matcher_fun)
       when is_binary(sql) do
    if String.starts_with?(Adapter.query_language(adapter), "sql") do
      schemas = candidate_schemas(adapter, search_path)
      matcher = matcher_fun.()

      blocked =
        sql
        |> Columns.table_names(Adapter.lexical_profile(adapter))
        |> Enum.flat_map(&hidden_relation(&1, schemas, matcher))
        |> Enum.uniq()
        |> Enum.sort()

      if blocked == [],
        do: :ok,
        else: {:error, "Query touches blocked table(s): #{format_relations(blocked)}"}
    else
      :ok
    end
  end

  defp named_relations_visible(_adapter, _statement, _search_path, _matcher_fun), do: :ok

  defp candidate_schemas(adapter, search_path) when is_binary(search_path) do
    case search_path
         |> String.split(",")
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> candidate_schemas(adapter, nil)
      schemas -> schemas
    end
  end

  defp candidate_schemas(adapter, _search_path) do
    case Adapter.default_schemas(adapter) do
      [] -> [nil]
      schemas -> schemas
    end
  end

  defp hidden_relation(path, schemas, matcher) do
    relations =
      case path do
        [table] -> Enum.map(schemas, &{&1, table})
        [schema, table] -> [{schema, table}]
        [_catalog, schema, table] -> [{schema, table}]
        _ -> []
      end

    hidden =
      Enum.map(relations, fn {schema, table} ->
        Enum.find(
          [{schema && String.downcase(schema), String.downcase(table)}, {schema, table}],
          fn rel ->
            not Visibility.allowed_relation?(matcher, rel)
          end
        )
      end)

    if hidden != [] and Enum.all?(hidden), do: Enum.take(hidden, 1), else: []
  end

  defp format_relations(relations) do
    relations
    |> Enum.map(fn
      {nil, table} -> table
      {schema, table} -> "#{schema}.#{table}"
    end)
  end

  defp normalize_preflight_error(e, _adapter) when is_binary(e) do
    strip_explain_query_tail(e)
  end

  defp normalize_preflight_error(e, adapter) do
    e
    |> then(&Adapter.format_error(adapter, &1))
    |> strip_explain_query_tail()
  end

  defp strip_explain_query_tail(msg) do
    Regex.replace(~r/\n?query:\s*EXPLAIN[\s\S]*\z/i, msg, "")
    |> String.trim_trailing()
  end
end
