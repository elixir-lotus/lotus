defmodule Lotus.Test.InMemoryAdapter do
  @moduledoc """
  In-memory, non-SQL adapter used by Lotus's own test suite to exercise the
  full adapter contract against a non-Ecto backend.

  The adapter treats each `%Statement{}` as a structured DSL map rather than
  a string:

      %{
        from: "users",
        where: [{"age", :gte, 18}, {"id", :eq, {:var, "user_id"}}],
        order_by: [{"created_at", :desc}],
        limit: 10,
        offset: 0
      }

  This shape sidesteps `Lotus.Storage.Query.to_sql_params/2` (which expects
  string text with `{{var}}` placeholders) — tests drive the adapter via
  `Lotus.Runner.run_statement/3` with a hand-built `%Statement{}`. Variable
  substitution is still exercised through `substitute_variable/5` and
  `substitute_list_variable/5`, both of which look for `{:var, name}`
  markers embedded in the `:where` clause.

  ## Dataset shape

  A dataset is a plain Elixir map:

      %{
        __lotus_adapter__: Lotus.Test.InMemoryAdapter,
        tables: %{
          "users" => %{
            columns: ["id", "name", "age", "status"],
            rows: [
              [1, "Alice", 30, "active"],
              [2, "Bob", 17, "active"]
            ],
            types: %{"id" => "integer", "name" => "text", "age" => "integer", "status" => "text"}
          }
        }
      }

  Register it the same way as any other source:

      config :lotus,
        data_sources: %{"mem" => Lotus.Test.InMemoryAdapter.dataset(tables: ...)},
        source_adapters: [Lotus.Test.InMemoryAdapter]

  ## Security note

  `substitute_variable/5` inlines values into the DSL directly. In a real
  non-SQL adapter this is the primary injection boundary — values would need
  to be rendered through a language-appropriate escaper (e.g.
  `Lotus.JSON.encode!/1` for a JSON DSL). Because the in-memory adapter
  carries values as native Elixir terms rather than serializing them, the
  concern doesn't arise here — but the pattern is documented loudly for
  adapter authors who copy this file as a starting template.
  """

  @behaviour Lotus.Source.Adapter

  alias Lotus.Query.Filter
  alias Lotus.Query.Sort
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter

  @source_type :in_memory
  @language "lotus:in_memory"

  # ---------------------------------------------------------------------------
  # Public helpers (test-only)
  # ---------------------------------------------------------------------------

  @doc """
  Build a dataset map that `can_handle?/1` and `wrap/2` will recognize.

      Lotus.Test.InMemoryAdapter.dataset(tables: %{"users" => %{columns: [...], rows: [...]}})

  ## Options

    * `:tables` — table name → `%{columns, rows, types}` map.
    * `:count_strategy` — `:separate` (default) or `:inline`. Controls how the
      adapter surfaces pre-pagination totals when the caller requests
      `count: :exact`:
        * `:separate` — Strategy B. `apply_pagination/3` stashes a
          `:count_spec` in `statement.meta`; Lotus core runs it as a
          second query.
        * `:inline` — Strategy A. `execute_query/4` returns
          `:total_count` directly in its result map.
  """
  @spec dataset(keyword()) :: map()
  def dataset(opts \\ []) do
    %{
      __lotus_adapter__: __MODULE__,
      tables: Keyword.get(opts, :tables, %{}),
      count_strategy: Keyword.get(opts, :count_strategy, :separate)
    }
  end

  @doc """
  Convenience: wrap a dataset directly without going through the resolver.

  Useful for unit tests that construct the `%Adapter{}` by hand.
  """
  @spec adapter(String.t(), map()) :: Adapter.t()
  def adapter(name \\ "mem", dataset) when is_binary(name) and is_map(dataset) do
    wrap(name, ensure_tagged(dataset))
  end

  # ---------------------------------------------------------------------------
  # Pluggable registration
  # ---------------------------------------------------------------------------

  @impl true
  def can_handle?(%{__lotus_adapter__: __MODULE__}), do: true
  def can_handle?(_), do: false

  @impl true
  def wrap(name, %{__lotus_adapter__: __MODULE__} = dataset) when is_binary(name) do
    %Adapter{
      name: name,
      module: __MODULE__,
      state: dataset,
      source_type: @source_type
    }
  end

  # ---------------------------------------------------------------------------
  # Query execution
  # ---------------------------------------------------------------------------

  @impl true
  def execute_query(state, text, params, _opts) do
    with {:ok, dsl} <- ensure_dsl(text),
         {:ok, table} <- fetch_table(state, dsl[:from]) do
      {rows, total} = run_dsl(dsl, table, params)
      columns = dsl[:select] || table.columns
      projected = project(rows, table.columns, columns)
      result = %{columns: columns, rows: projected, num_rows: length(projected)}

      # Strategy A: surface the pre-pagination total inline when the dataset
      # opted in AND the pagination step recorded the caller's :exact intent.
      result =
        if state[:count_strategy] == :inline and dsl[:count_mode] == :exact,
          do: Map.put(result, :total_count, total),
          else: result

      {:ok, result}
    end
  end

  @impl true
  def transaction(state, fun, _opts) when is_function(fun, 1) do
    {:ok, fun.(state)}
  end

  # ---------------------------------------------------------------------------
  # Introspection
  # ---------------------------------------------------------------------------

  @impl true
  def list_schemas(_state), do: {:ok, []}

  @impl true
  def list_tables(state, _schemas, _opts) do
    {:ok, state.tables |> Map.keys() |> Enum.sort() |> Enum.map(&{nil, &1})}
  end

  @impl true
  def describe_table(state, _schema, table) do
    case Map.fetch(state.tables, table) do
      {:ok, %{columns: cols} = t} ->
        types = Map.get(t, :types, %{})

        defs =
          Enum.map(cols, fn name ->
            %{
              name: name,
              type: Map.get(types, name, "text"),
              nullable: true,
              default: nil,
              primary_key: name == "id"
            }
          end)

        {:ok, defs}

      :error ->
        {:error, "Table #{inspect(table)} not found"}
    end
  end

  @impl true
  def resolve_table_namespace(_state, _table, _schemas), do: {:ok, nil}

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  @impl true
  def quote_identifier(_state, id), do: id

  @impl true
  def apply_filters(_state, %Statement{} = statement, filters) do
    dsl = ensure_dsl!(statement.text)
    where = Map.get(dsl, :where, [])

    new_where =
      where ++
        Enum.map(filters, fn %Filter{column: c, op: op, value: v} -> {c, op, v} end)

    %{statement | text: Map.put(dsl, :where, new_where)}
  end

  @impl true
  def apply_sorts(_state, %Statement{} = statement, sorts) do
    dsl = ensure_dsl!(statement.text)
    order = Map.get(dsl, :order_by, [])

    new_order =
      order ++
        Enum.map(sorts, fn
          %Sort{column: c, direction: d} -> {c, d}
          {c, d} -> {c, d}
          c when is_binary(c) -> {c, :asc}
        end)

    %{statement | text: Map.put(dsl, :order_by, new_order)}
  end

  @impl true
  def apply_pagination(state, %Statement{} = statement, opts) do
    dsl = ensure_dsl!(statement.text)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)
    count = Keyword.get(opts, :count, :none)

    new_text =
      dsl
      |> Map.put(:limit, limit)
      |> Map.put(:offset, offset)
      |> Map.put(:count_mode, count)

    # Strategy B (:separate, default) — record a :count_spec for core to run.
    # Strategy A (:inline) — execute_query will return :total_count with the
    # main result; no second query needed.
    meta =
      if count == :exact and state[:count_strategy] != :inline do
        count_dsl = dsl |> Map.drop([:limit, :offset, :count_mode]) |> Map.put(:count, true)
        Map.put(statement.meta, :count_spec, %{query: count_dsl, params: []})
      else
        statement.meta
      end

    %{statement | text: new_text, meta: meta}
  end

  @impl true
  def needs_preflight?(_state, _statement), do: true

  @impl true
  def query_plan(_state, _sql, _params, _opts), do: {:ok, nil}

  @impl true
  def substitute_variable(_state, %Statement{} = statement, var_name, value, _type) do
    with {:ok, dsl} <- ensure_dsl(statement.text) do
      new_where =
        dsl
        |> Map.get(:where, [])
        |> Enum.map(fn
          {col, op, {:var, ^var_name}} -> {col, op, value}
          other -> other
        end)

      {:ok, %{statement | text: Map.put(dsl, :where, new_where)}}
    end
  end

  @impl true
  def substitute_list_variable(_state, %Statement{} = statement, var_name, values, _type)
      when is_list(values) do
    with {:ok, dsl} <- ensure_dsl(statement.text) do
      new_where =
        dsl
        |> Map.get(:where, [])
        |> Enum.map(fn
          {col, :in, {:var, ^var_name}} -> {col, :in, values}
          other -> other
        end)

      {:ok, %{statement | text: Map.put(dsl, :where, new_where)}}
    end
  end

  @impl true
  def sanitize_query(_state, _statement, _opts), do: :ok

  @impl true
  def transform_bound_query(_state, statement, _opts), do: statement

  @impl true
  def transform_statement(_state, statement), do: statement

  @impl true
  def extract_accessed_resources(_state, %Statement{text: text}) do
    case ensure_dsl(text) do
      {:ok, %{from: table}} when is_binary(table) -> {:ok, MapSet.new([{nil, table}])}
      {:ok, _} -> {:unrestricted, "in-memory statement missing :from"}
      {:error, _} -> {:unrestricted, "in-memory adapter: non-DSL statement text"}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation & Identity rules
  # ---------------------------------------------------------------------------

  @impl true
  def validate_statement(state, %Statement{text: text}, _opts) do
    with {:ok, dsl} <- ensure_dsl(text),
         {:ok, _} <- fetch_table(state, dsl[:from]) do
      :ok
    end
  end

  @impl true
  def parse_qualified_name(_state, name) when is_binary(name), do: {:ok, [name]}

  @impl true
  def validate_identifier(_state, kind, value)
      when kind in [:schema, :table, :column] and is_binary(value) do
    if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, value),
      do: :ok,
      else: {:error, "invalid #{kind} identifier: #{inspect(value)}"}
  end

  @impl true
  def supported_filter_operators(_state),
    do: [:eq, :neq, :gt, :lt, :gte, :lte, :like, :is_null, :is_not_null]

  # ---------------------------------------------------------------------------
  # Safety & Visibility
  # ---------------------------------------------------------------------------

  @impl true
  def builtin_denies(_state), do: []

  @impl true
  def builtin_schema_denies(_state), do: []

  @impl true
  def default_schemas(_state), do: []

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def health_check(_state), do: :ok

  @impl true
  def disconnect(_state), do: :ok

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  @impl true
  def format_error(_state, error), do: inspect(error)

  @impl true
  def handled_errors(_state), do: []

  # ---------------------------------------------------------------------------
  # Identity & presentation
  # ---------------------------------------------------------------------------

  @impl true
  def source_type(_state), do: @source_type

  @impl true
  def supports_feature?(_state, _feature), do: false

  @impl true
  def query_language(_state), do: @language

  @impl true
  def limit_query(_state, statement, _limit), do: statement

  @impl true
  def hierarchy_label(_state), do: "Tables"

  @impl true
  def example_query(_state, table, _schema),
    do: ~s|%{from: "#{table}", where: [{"id", :eq, {:var, "id"}}]}|

  @impl true
  def editor_config(_state) do
    %{
      language: @language,
      keywords: ["from", "where", "order_by", "limit", "offset"],
      types: ["text", "integer", "boolean"],
      functions: [],
      context_boundaries: []
    }
  end

  @impl true
  def db_type_to_lotus_type(_state, _db_type), do: :text

  # ---------------------------------------------------------------------------
  # AI context
  # ---------------------------------------------------------------------------

  @impl true
  def ai_context(_state) do
    {:ok,
     %{
       language: @language,
       example_query: ~s|%{from: "users", where: [{"id", :eq, {:var, "user_id"}}]}|,
       syntax_notes:
         "Statements are Elixir maps: %{from: table, where: [{col, op, val}], " <>
           "order_by: [{col, :asc | :desc}], limit: n, offset: n}. " <>
           "Supported ops: :eq :neq :gt :lt :gte :lte :like :is_null :is_not_null :in. " <>
           "Values may be literals or `{:var, \"name\"}` for late binding.",
       error_patterns: [
         %{
           pattern: ~r/Table .* not found/,
           hint: "List available tables via describe_table or list_tables first."
         }
       ],
       capabilities: %{
         generation: true,
         optimization: {false, "In-memory adapter has no execution plan."},
         explanation: true
       }
     }}
  end

  @impl true
  def prepare_for_analysis(_state, _statement), do: {:error, :unsupported}

  # ---------------------------------------------------------------------------
  # Private — DSL execution
  # ---------------------------------------------------------------------------

  defp ensure_dsl(text) when is_map(text) and not is_struct(text), do: {:ok, text}
  defp ensure_dsl(_), do: {:error, "in-memory adapter: statement text must be a DSL map"}

  defp ensure_dsl!(text) do
    case ensure_dsl(text) do
      {:ok, dsl} -> dsl
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp fetch_table(state, table) when is_binary(table) do
    case Map.fetch(state.tables, table) do
      {:ok, %{columns: _, rows: _} = t} -> {:ok, t}
      :error -> {:error, "Table #{inspect(table)} not found"}
    end
  end

  defp fetch_table(_state, _), do: {:error, "in-memory statement missing :from"}

  defp ensure_tagged(%{__lotus_adapter__: __MODULE__} = d), do: d
  defp ensure_tagged(d), do: Map.put(d, :__lotus_adapter__, __MODULE__)

  # Returns `{page, total}` — `total` is the row count before pagination is
  # applied (what Strategy A surfaces as `:total_count`).
  defp run_dsl(dsl, %{columns: cols, rows: rows}, _params) do
    filtered_sorted =
      rows
      |> Enum.filter(&matches_all?(&1, cols, Map.get(dsl, :where, [])))
      |> sort_rows(cols, Map.get(dsl, :order_by, []))

    page = paginate(filtered_sorted, Map.get(dsl, :offset, 0), Map.get(dsl, :limit))
    {page, length(filtered_sorted)}
  end

  defp project(rows, source_cols, target_cols) when source_cols == target_cols, do: rows

  defp project(rows, source_cols, target_cols) do
    idx = Enum.map(target_cols, fn c -> Enum.find_index(source_cols, &(&1 == c)) end)
    Enum.map(rows, fn row -> Enum.map(idx, fn i -> if i, do: Enum.at(row, i), else: nil end) end)
  end

  defp matches_all?(_row, _cols, []), do: true

  defp matches_all?(row, cols, filters) do
    Enum.all?(filters, &matches?(row, cols, &1))
  end

  defp matches?(row, cols, {col, op, value}) do
    idx = Enum.find_index(cols, &(&1 == col))
    cell = if idx, do: Enum.at(row, idx), else: nil
    apply_op(op, cell, value)
  end

  defp apply_op(:eq, a, b), do: a == b
  defp apply_op(:neq, a, b), do: a != b
  defp apply_op(:gt, a, b), do: cmp(a, b) == :gt
  defp apply_op(:lt, a, b), do: cmp(a, b) == :lt
  defp apply_op(:gte, a, b), do: cmp(a, b) in [:gt, :eq]
  defp apply_op(:lte, a, b), do: cmp(a, b) in [:lt, :eq]
  defp apply_op(:like, a, b) when is_binary(a) and is_binary(b), do: like_match?(a, b)
  defp apply_op(:like, _, _), do: false
  defp apply_op(:is_null, a, _), do: is_nil(a)
  defp apply_op(:is_not_null, a, _), do: not is_nil(a)
  defp apply_op(:in, a, values) when is_list(values), do: a in values
  defp apply_op(_, _, _), do: false

  defp cmp(a, b) when a == b, do: :eq
  defp cmp(a, b) when a > b, do: :gt
  defp cmp(_, _), do: :lt

  defp like_match?(value, pattern) do
    regex_src =
      pattern
      |> Regex.escape()
      |> String.replace("%", ".*")
      |> String.replace("_", ".")

    Regex.match?(~r/\A#{regex_src}\z/s, value)
  end

  defp sort_rows(rows, _cols, []), do: rows

  defp sort_rows(rows, cols, order_by) do
    Enum.sort(rows, fn r1, r2 -> sort_compare(r1, r2, cols, order_by) end)
  end

  defp sort_compare(_r1, _r2, _cols, []), do: true

  defp sort_compare(r1, r2, cols, [{col, dir} | rest]) do
    idx = Enum.find_index(cols, &(&1 == col))
    v1 = if idx, do: Enum.at(r1, idx), else: nil
    v2 = if idx, do: Enum.at(r2, idx), else: nil

    cond do
      v1 == v2 -> sort_compare(r1, r2, cols, rest)
      dir == :asc -> v1 < v2
      dir == :desc -> v1 > v2
    end
  end

  defp paginate(rows, offset, nil), do: Enum.drop(rows, offset)
  defp paginate(rows, offset, limit), do: rows |> Enum.drop(offset) |> Enum.take(limit)
end
