defmodule Lotus.Schema do
  @moduledoc """
  Schema introspection functionality for Lotus.

  Provides functions to list schemas, tables and inspect table schemas across
  different database adapters (PostgreSQL, MySQL, SQLite, etc.).

  ## Visibility Filtering

  All schema and table listing functions automatically apply visibility rules
  configured in your application:

  - **Schema visibility** filters which schemas are accessible
  - **Table visibility** filters which tables within allowed schemas are accessible
  - **Built-in security** automatically blocks system schemas and tables

  Schema visibility takes precedence - if a schema is denied, all tables within it
  are blocked regardless of table-level rules.

  ## Middleware and Caching

  Every discovery call fires two middleware events (see `Lotus.Middleware`):

  1. The kind-specific `:after_list_*` event with a kind-specific payload.
  2. The unified `:after_discover` event with `%{kind:, source:, result:, context:}`.

  Both events run **outside** the cache callback — only the raw, visibility-filtered
  adapter result is cached. Context-sensitive middleware (e.g. per-tenant table
  filtering) is therefore safe to use without poisoning the cache, at the cost of
  running the middleware pipeline on every call.

  `Lotus.Visibility.Resolver` callbacks receive `(source_name, scope)`. When `scope`
  is `nil` (the default), cache keys are identical to pre-scope versions. When
  non-nil, a digest of the scope is appended to the cache key so different scopes
  produce independent cached entries. Keep scope low-cardinality for good cache
  hit rates.

  A resolver that reads runtime context (e.g. the process dictionary) instead of
  using the `scope` argument will cache incorrectly — place context-dependent
  logic in middleware or use `scope` to key the cache.

  ## Database-Specific Behavior

  - **PostgreSQL**: Returns namespaced `{schema, table}` tuples
  - **MySQL**: Returns `{database, table}` tuples (schemas = databases in MySQL)
  - **SQLite**: Returns table names as strings (schema-less)
  """

  alias Lotus.Cache.KeyBuilder
  alias Lotus.{Config, Middleware, Source, Telemetry, Visibility}
  alias Lotus.Source.Adapter
  alias Lotus.Visibility.Policy

  @doc """
  Lists all visible schemas in the given repository.

  Returns a list of schema names filtered by visibility rules. For databases
  without schemas (like SQLite), returns an empty list.

  **Note**: Results are automatically filtered by schema visibility rules.
  System schemas (like `pg_catalog`) are always blocked for security.

  ## Options

  - `:cache` - Cache options (profile, ttl_ms, etc.)
  - `:context` - Opaque value passed to the `:after_list_schemas` and
    `:after_discover` middleware events (see `Lotus.Middleware`)
  - `:scope` - Opaque value passed to the visibility resolver and hashed
    into the cache key. Different scopes produce independent cached entries.

  ## Examples

      {:ok, schemas} = Lotus.Schema.list_schemas(MyApp.Repo)
      # PostgreSQL: ["public", "reporting", ...]  (filtered by visibility)

      {:ok, schemas} = Lotus.Schema.list_schemas("mysql")
      # MySQL: ["app_production", "analytics_db", ...]  (databases = schemas)

      {:ok, schemas} = Lotus.Schema.list_schemas("sqlite")
      # SQLite: []  (schema-less database)
  """
  @spec list_schemas(module() | String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_schemas(repo_or_name, opts \\ []) do
    adapter = Source.resolve!(repo_or_name, nil)
    context = Keyword.get(opts, :context)
    scope = Keyword.get(opts, :scope)
    start_time = Telemetry.schema_introspection_start(:list_schemas, adapter.name)

    key = schema_key(:list_schemas, adapter.name, scope)
    tags = ["source:#{adapter.name}", "schema:list_schemas"] ++ scope_tags(scope)

    profile =
      if is_list(opts[:cache]) do
        Keyword.get(opts[:cache], :profile, :schema)
      else
        :schema
      end

    cache_result =
      exec_with_cache(opts[:cache], profile, key, tags, fn ->
        try do
          case Adapter.list_schemas(adapter) do
            {:ok, raw_schemas} ->
              {:ok, Visibility.filter_schemas(raw_schemas, adapter.name, scope)}

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    result =
      with {:ok, filtered_schemas} <- cache_result,
           {:ok, schemas} <-
             run_after_discover(:after_list_schemas, :schemas, %{
               source: adapter.name,
               schemas: filtered_schemas,
               scope: scope,
               context: context
             }) do
        run_after_discover_unified(:list_schemas, adapter.name, schemas, scope, context)
      end

    Telemetry.schema_introspection_stop(
      start_time,
      :list_schemas,
      adapter.name,
      result_status(result)
    )

    result
  end

  @doc """
  Lists all visible tables in the given repository.

  For databases with schemas (like PostgreSQL), returns {schema, table} tuples.
  For databases without schemas (like SQLite), returns just table names as strings.

  **Note**: Results are automatically filtered by visibility rules:

  1. Schema visibility is checked first - denied schemas block all their tables
  2. Table visibility is then applied to tables in allowed schemas
  3. System tables are always blocked for security

  ## Options

  - `:schema` - Search in specific schema (e.g., `schema: "reporting"`)
  - `:schemas` - Search in multiple schemas (e.g., `schemas: ["reporting", "public"]`)
  - `:search_path` - Use PostgreSQL search_path (e.g., `search_path: "reporting, public"`)
  - `:include_views` - Include views in results (default: false)
  - `:cache` - Cache options (profile, ttl_ms, etc.)
  - `:context` - Opaque value passed to the `:after_list_tables` and
    `:after_discover` middleware events (see `Lotus.Middleware`)
  - `:scope` - Opaque value passed to the visibility resolver and hashed
    into the cache key. Different scopes produce independent cached entries.

  ## Examples

      {:ok, tables} = Lotus.Schema.list_tables(MyApp.Repo)
      # PostgreSQL: [{"public", "users"}, {"public", "posts"}, ...]  (filtered by visibility)

      {:ok, tables} = Lotus.Schema.list_tables("postgres", search_path: "reporting, public")
      # PostgreSQL: [{"reporting", "customers"}, {"reporting", "orders"}, {"public", "users"}, ...]

      {:ok, tables} = Lotus.Schema.list_tables("mysql")
      # MySQL: [{"app_db", "users"}, {"analytics_db", "reports"}, ...]  (databases = schemas)

      {:ok, tables} = Lotus.Schema.list_tables("sqlite")
      # SQLite: ["products", "orders", "order_items"]  (schema-less)
  """
  @spec list_tables(module() | String.t(), keyword()) ::
          {:ok, [{String.t(), String.t()}] | [String.t()]} | {:error, term()}
  def list_tables(repo_or_name, opts \\ []) do
    adapter = Source.resolve!(repo_or_name, nil)
    context = Keyword.get(opts, :context)
    scope = Keyword.get(opts, :scope)
    start_time = Telemetry.schema_introspection_start(:list_tables, adapter.name)
    schemas = effective_schemas(adapter, opts)
    include_views? = Keyword.get(opts, :include_views, false)

    cache_result =
      case Visibility.validate_schemas(schemas, adapter.name, scope) do
        :ok ->
          search_path = Keyword.get(opts, :search_path)

          key =
            schema_key(
              :list_tables,
              adapter.name,
              search_path || Enum.join(schemas, ","),
              include_views?,
              scope
            )

          tags = ["source:#{adapter.name}", "schema:list_tables"] ++ scope_tags(scope)

          profile =
            if is_list(opts[:cache]) do
              Keyword.get(opts[:cache], :profile, :schema)
            else
              :schema
            end

          exec_with_cache(opts[:cache], profile, key, tags, fn ->
            try do
              case Adapter.list_tables(adapter, schemas, include_views: include_views?) do
                {:ok, raw_relations} ->
                  filtered =
                    raw_relations
                    |> Enum.filter(&Visibility.allowed_relation?(adapter.name, &1, scope))

                  tables =
                    if Enum.all?(filtered, fn {schema, _table} -> is_nil(schema) end) do
                      Enum.map(filtered, fn {nil, table} -> table end)
                    else
                      filtered
                    end

                  {:ok, tables}

                {:error, reason} ->
                  {:error, reason}
              end
            rescue
              e -> {:error, Exception.message(e)}
            end
          end)

        {:error, :schema_not_visible, denied: denied} ->
          {:error, "Schema(s) not visible: #{Enum.join(denied, ", ")}"}
      end

    result =
      with {:ok, filtered_tables} <- cache_result,
           {:ok, tables} <-
             run_after_discover(:after_list_tables, :tables, %{
               source: adapter.name,
               tables: filtered_tables,
               scope: scope,
               context: context
             }) do
        run_after_discover_unified(:list_tables, adapter.name, tables, scope, context)
      end

    Telemetry.schema_introspection_stop(
      start_time,
      :list_tables,
      adapter.name,
      result_status(result)
    )

    result
  end

  @doc """
  Describes a specific table (column definitions).

  Returns a list of column definitions with their types and constraints.

  ## Options

  - `:schema` - Look for table in specific namespace
  - `:schemas` - Search for table in multiple namespaces (first match wins)
  - `:search_path` - Use PostgreSQL search_path to resolve table location
  - `:cache` - Cache options (profile, ttl_ms, etc.)
  - `:context` - Opaque value passed to the `:after_describe_table` and
    `:after_discover` middleware events (see `Lotus.Middleware`)
  - `:scope` - Opaque value passed to the visibility resolver and hashed
    into the cache key. Different scopes produce independent cached entries.

  ## Examples

      {:ok, columns} = Lotus.Schema.describe_table(MyApp.Repo, "users")
      # Column definitions for public.users

      {:ok, columns} = Lotus.Schema.describe_table("postgres", "customers", schema: "reporting")
      # Column definitions for reporting.customers

      {:ok, columns} = Lotus.Schema.describe_table("postgres", "customers", search_path: "reporting, public")
      # Finds customers table using search_path resolution
  """
  @spec describe_table(module() | String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def describe_table(repo_or_name, table_name, opts \\ []) do
    adapter = Source.resolve!(repo_or_name, nil)
    context = Keyword.get(opts, :context)
    scope = Keyword.get(opts, :scope)
    start_time = Telemetry.schema_introspection_start(:describe_table, adapter.name)
    schemas = effective_schemas(adapter, opts)

    cache_result =
      case resolve_table_namespace_with_cache(
             adapter,
             table_name,
             schemas,
             opts[:cache],
             :schema
           ) do
        nil when schemas == [] ->
          # Schema-less database (SQLite) - nil is expected, proceed with nil schema
          {nil, describe_table_cached(adapter, table_name, nil, scope, opts)}

        nil ->
          {nil,
           {:error, "Table '#{table_name}' not found in schemas: #{Enum.join(schemas, ", ")}"}}

        {:error, reason} ->
          {nil, {:error, reason}}

        resolved_schema ->
          {resolved_schema,
           describe_table_cached(adapter, table_name, resolved_schema, scope, opts)}
      end

    result =
      case cache_result do
        {_resolved, {:error, _} = err} ->
          err

        {resolved_schema, {:ok, annotated}} ->
          with {:ok, columns} <-
                 run_after_discover(:after_describe_table, :columns, %{
                   source: adapter.name,
                   table_name: table_name,
                   schema: resolved_schema,
                   columns: annotated,
                   scope: scope,
                   context: context
                 }) do
            run_after_discover_unified(
              :describe_table,
              adapter.name,
              columns,
              scope,
              context
            )
          end
      end

    Telemetry.schema_introspection_stop(
      start_time,
      :describe_table,
      adapter.name,
      result_status(result)
    )

    result
  end

  defp describe_table_cached(adapter, table_name, resolved_schema, scope, opts) do
    key = schema_key(:describe_table, adapter.name, resolved_schema, table_name, scope)

    tags =
      [
        "source:#{adapter.name}",
        "schema:describe_table",
        "table:#{if resolved_schema, do: "#{resolved_schema}.#{table_name}", else: table_name}"
      ] ++ scope_tags(scope)

    profile =
      if is_list(opts[:cache]) do
        Keyword.get(opts[:cache], :profile, :schema)
      else
        :schema
      end

    exec_with_cache(opts[:cache], profile, key, tags, fn ->
      if Visibility.allowed_relation?(adapter.name, {resolved_schema, table_name}, scope) do
        fetch_and_annotate_columns(adapter, resolved_schema, table_name, scope)
      else
        {:error, table_not_visible_message(resolved_schema, table_name)}
      end
    end)
  end

  defp fetch_and_annotate_columns(adapter, resolved_schema, table_name, scope) do
    case Adapter.describe_table(adapter, resolved_schema, table_name) do
      {:ok, cols} ->
        annotated =
          annotate_columns_with_visibility(cols, adapter.name, resolved_schema, table_name, scope)

        {:ok, annotated}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp annotate_columns_with_visibility(cols, source_name, schema, table_name, scope) do
    rels = [{schema, table_name}]

    cols
    |> Enum.reduce([], fn col, acc ->
      policy = Visibility.column_policy_for(source_name, rels, col.name, scope)

      cond do
        Policy.hidden_from_schema?(policy) -> acc
        is_map(policy) -> [Map.put(col, :visibility, Map.take(policy, [:action, :mask])) | acc]
        true -> [col | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp table_not_visible_message(nil, table_name),
    do: "Table '#{table_name}' is not visible by Lotus policy"

  defp table_not_visible_message(schema, table_name),
    do: "Table '#{schema}.#{table_name}' is not visible by Lotus policy"

  @doc """
  Gets basic statistics about a table.

  Returns information like row count and table size.

  ## Options

  - `:schema` - Look for table in specific schema
  - `:schemas` - Search for table in multiple schemas (first match wins)
  - `:search_path` - Use PostgreSQL search_path to resolve table location
  - `:cache` - Cache options (profile, ttl_ms, etc.)

  ## Examples

      {:ok, stats} = Lotus.Schema.get_table_stats(MyApp.Repo, "users")
      # Returns: %{row_count: 1234}

      {:ok, stats} = Lotus.Schema.get_table_stats("postgres", "customers", schema: "reporting")
      # Gets stats for reporting.customers
  """
  @spec get_table_stats(module() | String.t(), String.t(), keyword()) ::
          {:ok, %{row_count: non_neg_integer()}} | {:error, binary()}
  def get_table_stats(repo_or_name, table_name, opts \\ []) do
    adapter = Source.resolve!(repo_or_name, nil)
    scope = Keyword.get(opts, :scope)
    start_time = Telemetry.schema_introspection_start(:get_table_stats, adapter.name)
    schemas = effective_schemas(adapter, opts)

    result =
      case resolve_table_namespace_with_cache(
             adapter,
             table_name,
             schemas,
             opts[:cache],
             :results
           ) do
        nil when schemas == [] ->
          get_table_stats_cached(adapter, table_name, nil, scope, opts)

        nil ->
          {:error, "Table '#{table_name}' not found in schemas: #{Enum.join(schemas, ", ")}"}

        {:error, reason} ->
          {:error, reason}

        resolved_schema ->
          get_table_stats_cached(adapter, table_name, resolved_schema, scope, opts)
      end

    Telemetry.schema_introspection_stop(
      start_time,
      :get_table_stats,
      adapter.name,
      result_status(result)
    )

    result
  end

  defp get_table_stats_cached(adapter, table_name, resolved_schema, scope, opts) do
    key = schema_key(:get_table_stats, adapter.name, resolved_schema, table_name, scope)

    tags =
      [
        "source:#{adapter.name}",
        "schema:get_table_stats",
        "table:#{if resolved_schema, do: "#{resolved_schema}.#{table_name}", else: table_name}"
      ] ++ scope_tags(scope)

    profile =
      if is_list(opts[:cache]) do
        Keyword.get(opts[:cache], :profile, :results)
      else
        :results
      end

    exec_with_cache(opts[:cache], profile, key, tags, fn ->
      if Visibility.allowed_relation?(adapter.name, {resolved_schema, table_name}, scope) do
        try do
          count_sql =
            if resolved_schema do
              qi = &Adapter.quote_identifier(adapter, &1)
              "SELECT COUNT(*) FROM #{qi.(resolved_schema)}.#{qi.(table_name)}"
            else
              qi = &Adapter.quote_identifier(adapter, &1)
              "SELECT COUNT(*) FROM #{qi.(table_name)}"
            end

          case Adapter.execute_query(adapter, count_sql, [], []) do
            {:ok, %{rows: [[count]]}} ->
              {:ok, %{row_count: count}}

            {:error, reason} ->
              {:error, to_string(reason)}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
      else
        {:error,
         "Table '#{if resolved_schema, do: "#{resolved_schema}.#{table_name}", else: table_name}' is not visible by Lotus policy"}
      end
    end)
  end

  @doc """
  Lists all relations (tables with namespace information) in the given repository.

  Similar to list_tables/2 but returns {schema, table} tuples instead of just table names.
  Useful for UIs that need to display the full namespace-qualified list.

  ## Options

  - `:schema` - Search in specific schema
  - `:schemas` - Search in multiple schemas
  - `:search_path` - Use PostgreSQL search_path
  - `:include_views` - Include views in results (default: false)
  - `:cache` - Cache options (profile, ttl_ms, etc.)
  - `:context` - Opaque value passed to the `:after_list_relations` and
    `:after_discover` middleware events (see `Lotus.Middleware`)
  - `:scope` - Opaque value passed to the visibility resolver and hashed
    into the cache key. Different scopes produce independent cached entries.

  ## Examples

      {:ok, relations} = Lotus.Schema.list_relations("postgres", search_path: "reporting, public")
      # Returns [{"reporting", "customers"}, {"reporting", "orders"}, {"public", "users"}, ...]
  """
  @spec list_relations(module() | String.t(), keyword()) ::
          {:ok, [{String.t() | nil, String.t()}]} | {:error, term()}
  def list_relations(repo_or_name, opts \\ []) do
    adapter = Source.resolve!(repo_or_name, nil)
    context = Keyword.get(opts, :context)
    scope = Keyword.get(opts, :scope)
    start_time = Telemetry.schema_introspection_start(:list_relations, adapter.name)
    schemas = effective_schemas(adapter, opts)
    include_views? = Keyword.get(opts, :include_views, false)

    search_path = Keyword.get(opts, :search_path)

    key =
      schema_key(
        :list_relations,
        adapter.name,
        search_path || Enum.join(schemas, ","),
        include_views?,
        scope
      )

    tags = ["source:#{adapter.name}", "schema:list_relations"] ++ scope_tags(scope)

    profile =
      if is_list(opts[:cache]) do
        Keyword.get(opts[:cache], :profile, :schema)
      else
        :schema
      end

    cache_result =
      exec_with_cache(opts[:cache], profile, key, tags, fn ->
        try do
          case Adapter.list_tables(adapter, schemas, include_views: include_views?) do
            {:ok, raw_relations} ->
              filtered =
                raw_relations
                |> Enum.filter(&Visibility.allowed_relation?(adapter.name, &1, scope))

              {:ok, filtered}

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    result =
      with {:ok, filtered_relations} <- cache_result,
           {:ok, relations} <-
             run_after_discover(:after_list_relations, :relations, %{
               source: adapter.name,
               relations: filtered_relations,
               scope: scope,
               context: context
             }) do
        run_after_discover_unified(:list_relations, adapter.name, relations, scope, context)
      end

    Telemetry.schema_introspection_stop(
      start_time,
      :list_relations,
      adapter.name,
      result_status(result)
    )

    result
  end

  defp run_after_discover(event, result_key, payload) do
    case Middleware.run(event, payload) do
      {:cont, updated} -> {:ok, Map.fetch!(updated, result_key)}
      {:halt, reason} -> {:error, reason}
    end
  end

  defp run_after_discover_unified(kind, source_name, result, scope, context) do
    payload = %{kind: kind, source: source_name, result: result, scope: scope, context: context}

    case Middleware.run(:after_discover, payload) do
      {:cont, %{result: new_result}} -> {:ok, new_result}
      {:halt, reason} -> {:error, reason}
    end
  end

  defp effective_schemas(adapter, opts) do
    schemas =
      cond do
        is_binary(Keyword.get(opts, :schema)) ->
          [Keyword.fetch!(opts, :schema)]

        is_list(Keyword.get(opts, :schemas)) ->
          Keyword.fetch!(opts, :schemas)

        is_binary(Keyword.get(opts, :search_path)) ->
          parse_search_path(Keyword.fetch!(opts, :search_path))

        true ->
          Adapter.default_schemas(adapter)
      end
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == "$user"))

    if schemas == [], do: Adapter.default_schemas(adapter), else: schemas
  end

  defp parse_search_path(sp) when is_binary(sp),
    do: sp |> String.split(",") |> Enum.map(&String.trim/1)

  # Returns: String.t() (resolved schema) | nil (not found) | {:error, term()} (adapter error)
  defp resolve_table_namespace_with_cache(
         adapter,
         table,
         schemas,
         cache_opts,
         default_profile
       ) do
    search_key = Enum.join(schemas, ",")
    key = schema_key(:resolve_table_namespace, adapter.name, search_key, table, nil)
    tags = ["source:#{adapter.name}", "schema:resolve_table_namespace", "table:#{table}"]

    profile =
      if is_list(cache_opts),
        do: Keyword.get(cache_opts, :profile, default_profile),
        else: default_profile

    cache_result =
      exec_with_cache(cache_opts, profile, key, tags, fn ->
        case Adapter.resolve_table_namespace(adapter, table, schemas) do
          {:ok, nil} -> {:ok, :not_found}
          {:ok, schema} -> {:ok, {:found, schema}}
          {:error, reason} -> {:error, reason}
        end
      end)

    case cache_result do
      {:ok, :not_found} -> nil
      {:ok, {:found, schema}} -> schema
      {:error, _} = err -> err
    end
  end

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
            :ok = Lotus.Cache.put(key, val, ttl, build_cache_options(cache_opts, tags))
            {:ok, val}

          other ->
            other
        end

      :use ->
        exec_with_cache_use(cache_opts, ttl_default_profile, key, tags, fun)
    end
  end

  defp exec_with_cache_use(cache_opts, ttl_default_profile, key, tags, fun) do
    ttl = choose_ttl(cache_opts, ttl_default_profile)
    opts = build_cache_options(cache_opts, tags)

    try do
      case Lotus.Cache.get_or_store(key, ttl, fn -> cache_value_or_throw(fun) end, opts) do
        {:ok, val, _meta} -> {:ok, val}
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
    base = [tags: tags]

    if is_list(cache_opts) do
      pass =
        cache_opts
        |> Enum.filter(fn
          {_k, _v} -> true
          _atom -> false
        end)
        |> Keyword.take([:max_bytes, :compress])

      Keyword.merge(pass, base)
    else
      base
    end
  end

  defp schema_key(kind, repo_name, scope) do
    key_builder().discovery_key(
      %{kind: kind, source_name: repo_name, components: {}, version: Lotus.version()},
      scope
    )
  end

  defp schema_key(kind, repo_name, comp1, comp2, scope) do
    key_builder().discovery_key(
      %{kind: kind, source_name: repo_name, components: {comp1, comp2}, version: Lotus.version()},
      scope
    )
  end

  defp scope_tags(nil), do: []

  defp scope_tags(scope) do
    ["scope:#{KeyBuilder.scope_digest(scope)}"]
  end

  defp key_builder, do: Config.cache_key_builder()

  defp result_status({:ok, _}), do: :ok
  defp result_status({:error, _}), do: :error
end
