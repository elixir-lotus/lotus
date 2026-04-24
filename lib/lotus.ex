defmodule Lotus do
  @moduledoc """
  Lotus is a lightweight Elixir library for saving and executing read-only SQL queries.

  This module provides the main public API, orchestrating between:
  - Storage: Query persistence and management
  - Runner: SQL execution with safety checks
  - Migrations: Database schema management

  ## Configuration

  Add to your config:

      config :lotus,
        storage_repo: MyApp.Repo,
        default_source: "main",
        data_sources: %{"main" => MyApp.Repo}

  ## Usage

      # Create and save a query with variables
      {:ok, query} = Lotus.create_query(%{
        name: "Active Users",
        statement: "SELECT * FROM users WHERE active = {{is_active}}",
        variables: [
          %{name: "is_active", type: :text, label: "Is Active", default: "true"}
        ],
        search_path: "reporting, public"
      })

      # Execute a saved query
      {:ok, results} = Lotus.run_query(query)

      # Execute SQL directly (read-only)
      {:ok, results} = Lotus.run_statement("SELECT * FROM products WHERE price > $1", [100])

  ## Further reading

    * [Source adapters guide](source-adapters.md) — how the adapter contract
      works, building custom SQL dialects or non-Ecto adapters, AI
      `ai_context` + trust boundary, security boundaries around variable
      substitution and visibility.
    * [Upgrading to v1.0](upgrading-to-v1.md) — step-by-step migration from
      v0.x (config renames, DB column rename, middleware/telemetry payload
      changes, adapter-contract updates).
  """

  @default_page_size 1000

  @type cache_opt ::
          :bypass
          | :refresh
          | {:ttl_ms, non_neg_integer()}
          | {:profile, atom()}
          | {:tags, [binary()]}

  @type window_count_mode :: :none | :exact

  @type window_opts :: [
          limit: pos_integer(),
          offset: non_neg_integer(),
          count: window_count_mode
        ]

  @type opts :: [
          timeout: non_neg_integer(),
          statement_timeout_ms: non_neg_integer(),
          read_only: boolean(),
          search_path: binary() | nil,
          repo: binary() | nil,
          vars: map(),
          cache: [cache_opt] | :bypass | :refresh | nil,
          window: window_opts,
          filters: [Filter.t()],
          context: term()
        ]

  alias Lotus.Cache.{Key, KeyBuilder}
  alias Lotus.{Config, Dashboards, Result, Runner, Schema, Source, Storage, Viz}
  alias Lotus.Query.{Filter, Sort, Statement}
  alias Lotus.Source.Adapter
  alias Lotus.Storage.Query
  alias Lotus.UnsupportedOperatorError

  def child_spec(opts), do: Lotus.Supervisor.child_spec(opts)
  def start_link(opts \\ []), do: Lotus.Supervisor.start_link(opts)

  @doc """
  Returns the current version of Lotus.
  """
  def version do
    Application.spec(:lotus, :vsn)
    |> to_string()
  end

  @doc """
  Returns the configured Ecto repository where Lotus stores query definitions.
  """
  def repo, do: Config.repo!()

  @doc """
  Returns all configured data sources.
  """
  def data_sources, do: Config.data_sources()

  @doc """
  Gets a data source by name.

  Raises if the source is not configured.
  """
  def get_data_source!(name), do: Config.get_data_source!(name)

  @doc """
  Lists the names of all configured data sources.

  Useful for building UI dropdowns.
  """
  def list_data_source_names, do: Config.list_data_source_names()

  @doc """
  Returns the default data source as a {name, module} tuple.

  - If there's only one data source configured, returns it
  - If multiple sources are configured and default_source is set, returns that source
  - If multiple sources are configured without default_source, raises an error
  - If no data sources are configured, raises an error
  """
  def default_data_source, do: Config.default_data_source()

  @doc """
  Lists all saved queries.
  """
  defdelegate list_queries(), to: Storage

  @doc """
  Gets a single query by ID. Returns nil if not found.
  """
  defdelegate get_query(id), to: Storage

  @doc """
  Gets a single query by ID. Raises if not found.
  """
  defdelegate get_query!(id), to: Storage

  @doc """
  Creates a new saved query.
  """
  defdelegate create_query(attrs), to: Storage

  @doc """
  Updates an existing query.
  """
  defdelegate update_query(query, attrs), to: Storage

  @doc """
  Deletes a saved query.
  """
  defdelegate delete_query(query), to: Storage

  # ── Visualization Functions ─────────────────────────────────────────────────

  @doc """
  Lists all visualizations for a query.

  Returns visualizations ordered by position, then by id.
  """
  defdelegate list_visualizations(query_or_id), to: Viz

  @doc """
  Creates a new visualization for a query.
  """
  defdelegate create_visualization(query_or_id, attrs), to: Viz

  @doc """
  Updates an existing visualization.
  """
  defdelegate update_visualization(viz, attrs), to: Viz

  @doc """
  Deletes a visualization (by struct or id).
  """
  defdelegate delete_visualization(viz_or_id), to: Viz

  @doc """
  Validates a visualization config against query results.

  Checks that all referenced fields exist in the result columns and that
  numeric aggregations (sum, avg) are applied only to numeric columns.
  """
  defdelegate validate_visualization_config(config, result),
    to: Viz,
    as: :validate_against_result

  # ── Dashboard Functions ────────────────────────────────────────────────────

  @doc """
  Lists all dashboards.

  ## Options

    * `:preload` - A list of associations to preload (e.g., `[:cards]`)
  """
  defdelegate list_dashboards(opts \\ []), to: Dashboards

  @doc """
  Lists dashboards with optional filtering.

  ## Options

    * `:search` - Search term to match against dashboard names
  """
  defdelegate list_dashboards_by(opts), to: Dashboards

  @doc """
  Gets a single dashboard by ID. Returns nil if not found.
  """
  defdelegate get_dashboard(id), to: Dashboards

  @doc """
  Gets a single dashboard by ID. Raises if not found.
  """
  defdelegate get_dashboard!(id), to: Dashboards

  @doc """
  Gets a dashboard by its public sharing token.
  """
  defdelegate get_dashboard_by_token(token), to: Dashboards

  @doc """
  Creates a new dashboard.
  """
  defdelegate create_dashboard(attrs), to: Dashboards

  @doc """
  Updates an existing dashboard.
  """
  defdelegate update_dashboard(dashboard, attrs), to: Dashboards

  @doc """
  Deletes a dashboard.
  """
  defdelegate delete_dashboard(dashboard), to: Dashboards

  @doc """
  Enables public sharing for a dashboard by generating a unique token.
  """
  defdelegate enable_public_sharing(dashboard), to: Dashboards

  @doc """
  Disables public sharing for a dashboard.
  """
  defdelegate disable_public_sharing(dashboard), to: Dashboards

  # ── Dashboard Card Functions ───────────────────────────────────────────────

  @doc """
  Lists all cards for a dashboard.

  ## Options

    * `:preload` - A list of associations to preload (e.g., `[:query, :filter_mappings]`)

  """
  defdelegate list_dashboard_cards(dashboard_or_id, opts \\ []), to: Dashboards

  @doc """
  Gets a single card by ID. Returns nil if not found.

  ## Options

    * `:preload` - A list of associations to preload

  """
  defdelegate get_dashboard_card(id, opts \\ []), to: Dashboards

  @doc """
  Gets a single card by ID. Raises if not found.

  ## Options

    * `:preload` - A list of associations to preload

  """
  defdelegate get_dashboard_card!(id, opts \\ []), to: Dashboards

  @doc """
  Creates a new card for a dashboard.
  """
  defdelegate create_dashboard_card(dashboard_or_id, attrs), to: Dashboards

  @doc """
  Updates a card.
  """
  defdelegate update_dashboard_card(card, attrs), to: Dashboards

  @doc """
  Deletes a card.
  """
  defdelegate delete_dashboard_card(card_or_id), to: Dashboards

  @doc """
  Reorders cards in a dashboard.
  """
  defdelegate reorder_dashboard_cards(dashboard_or_id, card_ids), to: Dashboards

  # ── Dashboard Filter Functions ─────────────────────────────────────────────

  @doc """
  Lists all filters for a dashboard.
  """
  defdelegate list_dashboard_filters(dashboard_or_id), to: Dashboards

  @doc """
  Gets a single filter by ID. Returns nil if not found.
  """
  defdelegate get_dashboard_filter(id), to: Dashboards

  @doc """
  Gets a single filter by ID. Raises if not found.
  """
  defdelegate get_dashboard_filter!(id), to: Dashboards

  @doc """
  Creates a new filter for a dashboard.
  """
  defdelegate create_dashboard_filter(dashboard_or_id, attrs), to: Dashboards

  @doc """
  Updates a filter.
  """
  defdelegate update_dashboard_filter(filter, attrs), to: Dashboards

  @doc """
  Deletes a filter.
  """
  defdelegate delete_dashboard_filter(filter_or_id), to: Dashboards

  # ── Filter Mapping Functions ───────────────────────────────────────────────

  @doc """
  Creates a filter mapping connecting a dashboard filter to a card's query variable.
  """
  defdelegate create_filter_mapping(card, filter, variable_name, opts \\ []), to: Dashboards

  @doc """
  Deletes a filter mapping.
  """
  defdelegate delete_filter_mapping(mapping_or_id), to: Dashboards

  @doc """
  Lists all filter mappings for a card.
  """
  defdelegate list_card_filter_mappings(card_or_id), to: Dashboards

  # ── Dashboard Execution Functions ──────────────────────────────────────────

  @doc """
  Runs all query cards in a dashboard and returns their results.

  Returns a map of card IDs to their results.

  ## Options

    * `:filter_values` - Map of filter names to their current values
    * `:parallel` - Whether to run cards in parallel (default: true)
    * `:timeout` - Timeout per card in milliseconds (default: 30000)
  """
  defdelegate run_dashboard(dashboard_or_id, opts \\ []), to: Dashboards

  @doc """
  Runs a single dashboard card and returns its result.

  ## Options

    * `:filter_values` - Map of filter names to their current values
    * `:timeout` - Query timeout in milliseconds
  """
  defdelegate run_dashboard_card(card_or_id, opts \\ []), to: Dashboards

  @doc """
  Run a saved query (by struct or id).

  Variables in the query statement (using `{{variable_name}}` syntax) are
  substituted with values from the query's default variables and any runtime
  overrides provided via the `vars` option.

  ## Variable Resolution

  Variables are resolved in this order:
  1. Runtime values from `vars` option (highest priority)
  2. Default values from the query's variable definitions
  3. If neither exists, raises an error for missing required variable

  ## Examples

      # Run query with default variable values
      Lotus.run_query(query)

      # Override variables at runtime
      Lotus.run_query(query, vars: %{"min_age" => 25, "status" => "active"})

      # Run with timeout and repo options
      Lotus.run_query(query, timeout: 10_000, repo: MyApp.DataRepo)

      # Run by query ID
      Lotus.run_query(query_id, vars: %{"user_id" => 123})

  ## Variable Types

  Variables are automatically cast based on their type definition:
  - `:text` - Used as-is (strings)
  - `:number` - Cast from string to integer
  - `:date` - Cast from ISO8601 string to Date struct


  ### Windowed pagination
  Pass `window: [limit: pos_integer, offset: non_neg_integer, count: :none | :exact]` to
  return only a page of rows from the original query. When `count: :exact`, Lotus will
  also compute `SELECT COUNT(*) FROM (original_sql)` and include `meta.total_count` in
  the result. The `num_rows` field always reflects the number of rows in the returned page.
  """
  @spec run_query(Query.t() | term(), opts()) :: {:ok, Result.t()} | {:error, term()}
  def run_query(query_or_id, opts \\ [])

  def run_query(%Query{} = q, opts) do
    vars = prepare_variables(q, opts)

    case Query.to_sql_params(q, vars) do
      {:ok, sql, params} ->
        execute_query(q, sql, params, vars, opts)

      {:error, _} = err ->
        err
    end
  end

  def run_query(id, opts) do
    q = Storage.get_query!(id)
    run_query(q, opts)
  end

  defp prepare_variables(q, opts) do
    supplied_vars = Keyword.get(opts, :vars, %{}) || %{}

    defaults =
      q.variables
      |> Enum.filter(& &1.default)
      |> Map.new(fn v -> {v.name, v.default} end)

    Map.merge(defaults, supplied_vars)
  end

  defp execute_query(q, sql, params, vars, opts) do
    adapter = Source.resolve!(Keyword.get(opts, :repo), q.data_source)
    search_path = Keyword.get(opts, :search_path) || q.search_path
    runner_opts = prepare_final_opts(opts, search_path)

    execute_with_options(adapter, sql, params, opts, runner_opts, vars, q.id)
  end

  defp execute_with_options(adapter, sql, params, opts, runner_opts, cache_identity, query_id) do
    search_path = Keyword.get(runner_opts, :search_path)

    statement = %Statement{adapter: adapter.module, text: sql, params: params}
    statement = Adapter.transform_bound_query(adapter, statement, runner_opts)

    filters = Keyword.get(opts, :filters, [])
    :ok = validate_filter_columns!(adapter, filters)
    :ok = validate_filter_operators!(adapter, filters)
    statement = Adapter.apply_filters(adapter, statement, filters)

    sorts = Keyword.get(opts, :sorts, [])
    :ok = validate_sort_columns!(adapter, sorts)
    statement = Adapter.apply_sorts(adapter, statement, sorts)

    {statement, pagination_meta, cache_bound} =
      maybe_paginate(statement, adapter, search_path, Keyword.get(opts, :window))

    scope = Keyword.get(opts, :scope)

    key =
      result_key(statement.text, cache_bound || cache_identity, adapter.name, search_path, scope)

    tags = build_cache_tags(query_id, adapter.name, opts)
    profile = determine_cache_profile(opts)

    exec_with_cache(opts[:cache], profile, key, tags, fn ->
      with {:ok, %Result{} = res} <- Runner.run_statement(adapter, statement, runner_opts) do
        {:ok, merge_pagination_meta(res, pagination_meta)}
      end
    end)
  end

  defp prepare_final_opts(opts, nil),
    do: Keyword.put_new_lazy(opts, :read_only, &Config.read_only?/0)

  defp prepare_final_opts(opts, search_path) do
    opts
    |> Keyword.put(:search_path, search_path)
    |> Keyword.put_new_lazy(:read_only, &Config.read_only?/0)
  end

  defp build_cache_tags(query_id, repo_name, opts) do
    base_tags =
      case query_id do
        nil -> ["source:#{repo_name}"]
        id -> ["query:#{id}", "source:#{repo_name}"]
      end

    custom_tags =
      case opts[:cache] do
        cache_opts when is_list(cache_opts) -> Keyword.get(cache_opts, :tags, [])
        _ -> []
      end

    base_tags ++ custom_tags ++ scope_tags(opts[:scope])
  end

  defp scope_tags(nil), do: []

  defp scope_tags(scope) do
    ["scope:#{KeyBuilder.scope_digest(scope)}"]
  end

  defp determine_cache_profile(opts) do
    case opts[:cache] do
      cache_opts when is_list(cache_opts) ->
        Keyword.get(cache_opts, :profile, Config.default_cache_profile())

      _ ->
        Config.default_cache_profile()
    end
  end

  @doc """
  Checks if a query can be run with the provided variables.

  Returns true if all required variables have values (either from defaults
  or supplied vars), false otherwise.

  ## Examples

      # Query with all required variables having defaults
      Lotus.can_run?(query)
      # => true

      # Query missing required variables
      Lotus.can_run?(query)
      # => false

      # Query with runtime variable overrides
      Lotus.can_run?(query, vars: %{"user_id" => 123})
      # => true (if user_id was the missing variable)

  """
  @spec can_run?(Query.t()) :: boolean()
  @spec can_run?(Query.t(), opts()) :: boolean()
  def can_run?(query, opts \\ [])

  def can_run?(%Query{} = q, opts) do
    vars = prepare_variables(q, opts)
    match?({:ok, _, _}, Query.to_sql_params(q, vars))
  end

  @doc """
  Run ad-hoc SQL (bypassing storage), read-only by default and sandboxed.

  ## Options

    * `:read_only` — when `true` (default), blocks write operations (INSERT, UPDATE,
      DELETE, DDL) at both the application and database level. Set to `false` to allow
      write queries.

  ## Examples

      # Run against default configured repo
      {:ok, result} = Lotus.run_statement("SELECT * FROM users")

      # Run against specific repo
      {:ok, result} = Lotus.run_statement("SELECT * FROM products", [], repo: MyApp.DataRepo)

      # With parameters
      {:ok, result} = Lotus.run_statement("SELECT * FROM users WHERE id = $1", [123])

      # With search_path for schema resolution
      {:ok, result} = Lotus.run_statement("SELECT * FROM users", [], search_path: "reporting, public")

      # Allow write queries (development use)
      {:ok, result} = Lotus.run_statement(
        "INSERT INTO notes (body) VALUES ($1)",
        ["hello"],
        read_only: false
      )

  ### Windowed pagination
  Pass `window: [limit: pos_integer, offset: non_neg_integer, count: :none | :exact]` to
  page results from the SQL. See `run_query/2` for details. The cache key automatically
  incorporates the window so different pages are cached independently.
  """
  @spec run_statement(binary(), list(any()), [
          {:read_only, boolean()}
          | {:statement_timeout_ms, non_neg_integer()}
          | {:timeout, non_neg_integer()}
          | {:search_path, binary() | nil}
          | {:repo, atom() | binary()}
          | {:window, window_opts}
        ]) ::
          {:ok, Result.t()} | {:error, term()}
  def run_statement(statement, params \\ [], opts \\ []) do
    adapter = Source.resolve!(Keyword.get(opts, :repo), nil)

    runner_opts =
      opts
      |> Keyword.delete(:repo)
      |> Keyword.put_new_lazy(:read_only, &Config.read_only?/0)

    execute_with_options(adapter, statement, params, opts, runner_opts, params, nil)
  end

  @doc """
  Returns whether unique query names are enforced.
  """
  defdelegate unique_names?(), to: Config

  @doc """
  Lists all tables in a data repository.

  For databases with schemas (PostgreSQL), returns {schema, table} tuples.
  For databases without schemas (SQLite), returns just table names as strings.

  ## Options

  - `:context` — opaque value threaded into the `:after_list_tables` and
    `:after_discover` middleware events. See `Lotus.Middleware`.
  - `:scope` — opaque value passed to the visibility resolver and hashed
    into the cache key. Different scopes produce independent cached entries.
    See `Lotus.Visibility.Resolver`.

  ## Examples

      {:ok, tables} = Lotus.list_tables("postgres")
      # Returns [{"public", "users"}, {"public", "posts"}, ...]

      {:ok, tables} = Lotus.list_tables("postgres", search_path: "reporting, public")
      # Returns [{"reporting", "customers"}, {"public", "users"}, ...]

      {:ok, tables} = Lotus.list_tables("sqlite")
      # Returns ["products", "orders", "order_items"]

      {:ok, tables} = Lotus.list_tables("postgres", context: %{tenant: "acme"})
      # Middleware sees `%{tenant: "acme"}` in the payload

      {:ok, tables} = Lotus.list_tables("postgres", scope: %{role: :admin})
      # Visibility resolver receives scope; result cached separately per scope
  """
  def list_tables(repo_or_name, opts \\ []), do: Schema.list_tables(repo_or_name, opts)

  @doc """
  Lists all schemas in the given repository.

  Returns a list of schema names. For databases without schemas (like SQLite),
  returns an empty list.

  ## Options

  - `:context` — opaque value threaded into the `:after_list_schemas` and
    `:after_discover` middleware events.
  - `:scope` — opaque value passed to the visibility resolver and hashed
    into the cache key. See `Lotus.Visibility.Resolver`.

  ## Examples

      {:ok, schemas} = Lotus.list_schemas("postgres")
      # Returns ["public", "reporting", ...]

      {:ok, schemas} = Lotus.list_schemas("sqlite")
      # Returns []
  """
  def list_schemas(repo_or_name, opts \\ []), do: Schema.list_schemas(repo_or_name, opts)

  @doc """
  Describes a specific table, returning its column definitions.

  ## Options

  - `:context` — opaque value threaded into the `:after_describe_table`
    and `:after_discover` middleware events.
  - `:scope` — opaque value passed to the visibility resolver and hashed
    into the cache key. See `Lotus.Visibility.Resolver`.

  ## Examples

      {:ok, columns} = Lotus.describe_table("primary", "users")
      {:ok, columns} = Lotus.describe_table("postgres", "customers", schema: "reporting")
      {:ok, columns} = Lotus.describe_table(MyApp.DataRepo, "products", search_path: "analytics, public")
  """
  def describe_table(repo_or_name, table_name, opts \\ []),
    do: Schema.describe_table(repo_or_name, table_name, opts)

  @doc """
  Gets statistics for a specific table.

  ## Examples

      {:ok, stats} = Lotus.get_table_stats("primary", "users")
      {:ok, stats} = Lotus.get_table_stats("postgres", "customers", schema: "reporting")
      # Returns %{row_count: 1234}
  """
  def get_table_stats(repo_or_name, table_name, opts \\ []),
    do: Schema.get_table_stats(repo_or_name, table_name, opts)

  @doc """
  Lists all relations (tables with column information) in a data repository.

  ## Options

  - `:context` — opaque value threaded into the `:after_list_relations` and
    `:after_discover` middleware events.
  - `:scope` — opaque value passed to the visibility resolver and hashed
    into the cache key. See `Lotus.Visibility.Resolver`.

  ## Examples

      {:ok, relations} = Lotus.list_relations("postgres", search_path: "reporting, public")
      # Returns [{"reporting", "customers"}, {"public", "users"}, ...]
  """
  def list_relations(repo_or_name, opts \\ []), do: Schema.list_relations(repo_or_name, opts)

  @doc """
  Invalidates all cached discovery entries associated with the given scope.

  Uses tag-based invalidation — each scoped cache entry is tagged with a
  scope digest, so this clears only entries for the specified scope without
  flushing the entire cache.

  ## Examples

      :ok = Lotus.invalidate_scope(%{tenant_id: 42})
      :ok = Lotus.invalidate_scope(%{role: :admin})
  """
  defdelegate invalidate_scope(scope), to: Lotus.Cache

  defp cache_mode(nil) do
    case Config.cache_adapter() do
      {:ok, _adapter} -> :use
      :error -> :off
    end
  end

  defp cache_mode(:bypass), do: :bypass
  defp cache_mode(:refresh), do: :refresh

  defp cache_mode(opts) when is_list(opts) do
    cond do
      :bypass in opts -> :bypass
      :refresh in opts -> :refresh
      true -> :use
    end
  end

  defp choose_ttl(cache_opts, default_profile) do
    get_explicit_ttl(cache_opts) || get_profile_ttl(cache_opts, default_profile)
  end

  defp get_explicit_ttl(cache_opts) when is_list(cache_opts) do
    Keyword.get(cache_opts, :ttl_ms)
  end

  defp get_explicit_ttl(_), do: nil

  defp get_profile_ttl(cache_opts, default_profile) do
    profile = determine_profile(cache_opts, default_profile)

    Config.cache_profile_settings(profile)[:ttl_ms] ||
      get_default_ttl() ||
      :timer.seconds(60)
  end

  defp determine_profile(cache_opts, default_profile) when is_list(cache_opts) do
    Keyword.get(cache_opts, :profile, default_profile || Config.default_cache_profile())
  end

  defp determine_profile(_cache_opts, nil), do: Config.default_cache_profile()
  defp determine_profile(_cache_opts, default_profile), do: default_profile

  defp get_default_ttl do
    case Config.cache_config() do
      nil -> nil
      config -> config[:default_ttl_ms]
    end
  end

  defp exec_with_cache(cache_opts, ttl_default_profile, key, tags, fun) do
    case cache_mode(cache_opts) do
      :off ->
        fun.()

      :bypass ->
        fun.()

      :refresh ->
        case fun.() do
          {:ok, val} ->
            ttl = choose_ttl(cache_opts, ttl_default_profile)
            cache_options = build_cache_options(cache_opts, tags)
            :ok = Lotus.Cache.put(key, val, ttl, cache_options)
            {:ok, val}

          error ->
            error
        end

      :use ->
        exec_with_cache_use(cache_opts, ttl_default_profile, key, tags, fun)
    end
  end

  defp exec_with_cache_use(cache_opts, ttl_default_profile, key, tags, fun) do
    ttl = choose_ttl(cache_opts, ttl_default_profile)

    try do
      cache_options = build_cache_options(cache_opts, tags)

      case Lotus.Cache.get_or_store(key, ttl, fn -> cache_value_or_throw(fun) end, cache_options) do
        {:ok, val, _} -> {:ok, val}
        {:error, _} -> fun.()
      end
    catch
      {:lotus_cache_error, e} -> {:error, e}
    end
  end

  defp cache_value_or_throw(fun) do
    case fun.() do
      {:ok, val} -> val
      {:error, e} -> throw({:lotus_cache_error, e})
    end
  end

  defp build_cache_options(cache_opts, tags) do
    base_options = [tags: tags]

    if is_list(cache_opts) do
      cache_options =
        cache_opts
        |> Enum.filter(fn
          {_key, _value} -> true
          _atom -> false
        end)
        |> Keyword.take([:max_bytes, :compress])

      Keyword.merge(cache_options, base_options)
    else
      base_options
    end
  end

  defp result_key(sql, bound_vars_map, repo_name, search_path, scope) do
    Key.result(
      sql,
      bound_vars_map,
      [data_source: repo_name, search_path: search_path, lotus_version: Lotus.version()],
      scope
    )
  end

  defp resolve_window_limit(window_opts) do
    max_limit = Config.default_page_size() || @default_page_size

    case Keyword.get(window_opts, :limit) do
      nil ->
        max_limit

      limit when not is_integer(limit) or limit <= 0 ->
        max_limit

      limit ->
        min(limit, max_limit)
    end
  end

  # Pipeline-level validation of caller-supplied filter/sort column names
  # and filter operators. Catches mismatches (unknown columns, operators the
  # adapter can't handle) before we ever hand them to `apply_filters/3` /
  # `apply_sorts/3` — so the failure mode is a clear error at the boundary,
  # not a cryptic SQL/DSL error from deep inside the adapter.
  defp validate_filter_columns!(_adapter, []), do: :ok

  defp validate_filter_columns!(adapter, filters) do
    Enum.each(filters, fn %Filter{column: col} ->
      case Adapter.validate_identifier(adapter, :column, col) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, reason
      end
    end)

    :ok
  end

  defp validate_sort_columns!(_adapter, []), do: :ok

  defp validate_sort_columns!(adapter, sorts) do
    Enum.each(sorts, fn
      %Sort{column: col} -> check_column!(adapter, col)
      col when is_binary(col) -> check_column!(adapter, col)
      _other -> :ok
    end)

    :ok
  end

  defp check_column!(adapter, col) do
    case Adapter.validate_identifier(adapter, :column, col) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp validate_filter_operators!(_adapter, []), do: :ok

  defp validate_filter_operators!(adapter, filters) do
    supported = Adapter.supported_filter_operators(adapter)

    Enum.each(filters, fn %Filter{op: op} ->
      unless op in supported do
        raise UnsupportedOperatorError,
          operator: op,
          source: adapter.name,
          supported: supported
      end
    end)

    :ok
  end

  defp maybe_paginate(%Statement{} = statement, _adapter, _search_path, nil),
    do: {statement, nil, nil}

  defp maybe_paginate(
         %Statement{params: params} = statement,
         adapter,
         search_path,
         pagination_opts
       )
       when is_list(pagination_opts) do
    limit = resolve_window_limit(pagination_opts)
    offset = Keyword.get(pagination_opts, :offset, 0)
    count_mode = Keyword.get(pagination_opts, :count, :none)

    callback_opts = [limit: limit, offset: offset, count: count_mode, search_path: search_path]

    paged_statement = Adapter.apply_pagination(adapter, statement, callback_opts)
    count_spec = Map.get(paged_statement.meta, :count_spec)

    # `total_mode` reflects what the caller requested — not how the adapter
    # chose to fulfil it. Strategy A adapters (inline count via the main
    # query result) don't set :count_spec but still need :exact plumbed
    # through so merge_pagination_meta/2 surfaces the total.
    pagination_meta = %{
      window: %{limit: limit, offset: offset},
      total_mode: count_mode,
      count_spec: count_spec,
      adapter: adapter,
      search_path: search_path
    }

    cache_bound = %{
      __params__: params,
      __window__: %{limit: limit, offset: offset, count: count_mode}
    }

    {paged_statement, pagination_meta, cache_bound}
  end

  defp merge_pagination_meta(%Result{} = res, nil), do: res

  defp merge_pagination_meta(%Result{} = res, %{total_mode: :none, window: win}) do
    updated_meta = Map.merge(res.meta, %{window: win})
    %Result{res | num_rows: length(res.rows), meta: updated_meta}
  end

  defp merge_pagination_meta(%Result{} = res, %{total_mode: :exact} = meta) do
    win = Map.fetch!(meta, :window)

    # Precedence: adapter-supplied inline count (Strategy A) wins over
    # :count_spec (Strategy B). If neither yields a count, fall back to nil.
    total_count =
      cond do
        is_integer(res.meta[:total_count]) ->
          res.meta[:total_count]

        is_map(meta[:count_spec]) ->
          case do_count(meta) do
            {:ok, n} when is_integer(n) and n >= 0 -> n
            _ -> nil
          end

        true ->
          nil
      end

    updated_meta =
      Map.merge(res.meta, %{window: win, total_count: total_count, total_mode: :exact})

    %Result{
      res
      | num_rows: length(res.rows),
        meta: updated_meta
    }
  end

  defp do_count(%{count_spec: %{query: q, params: ps}, adapter: adapter} = meta) do
    runner_opts = build_runner_opts(meta)
    statement = %Statement{adapter: adapter.module, text: q, params: ps}

    adapter
    |> Runner.run_statement(statement, runner_opts)
    |> parse_count_result()
  end

  defp build_runner_opts(meta) do
    case Map.get(meta, :search_path) do
      sp when is_binary(sp) and byte_size(sp) > 0 -> [search_path: sp]
      _ -> []
    end
  end

  defp parse_count_result({:ok, %Result{rows: [[n]]}} = _result) when is_integer(n) do
    {:ok, n}
  end

  defp parse_count_result({:ok, %Result{rows: [[n]]}} = _result) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> {:ok, v}
      _ -> {:error, :invalid_count}
    end
  end

  defp parse_count_result({:ok, %Result{rows: _}}), do: {:error, :invalid_count}
  defp parse_count_result(other), do: other
end
