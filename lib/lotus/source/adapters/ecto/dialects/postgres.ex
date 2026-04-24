defmodule Lotus.Source.Adapters.Ecto.Dialects.Postgres do
  @moduledoc false

  @behaviour Lotus.Source.Adapters.Ecto.Dialect

  alias __MODULE__.EditorConfig
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto.Dialects.Default
  alias Lotus.Source.Adapters.Ecto.SQL.FilterInjector
  alias Lotus.Source.Adapters.Ecto.SQL.Identifier
  alias Lotus.Source.Adapters.Ecto.SQL.SortInjector

  @default_statement_timeout_ms 5_000

  @impl true
  def source_type, do: :postgres

  @impl true
  def ecto_adapter, do: Ecto.Adapters.Postgres

  @impl true
  def execute_in_transaction(repo, fun, opts) do
    read_only? = Keyword.get(opts, :read_only, true)
    stmt_ms = Keyword.get(opts, :statement_timeout_ms, @default_statement_timeout_ms)
    timeout = Keyword.get(opts, :timeout, 15_000)
    search_path = Keyword.get(opts, :search_path)

    repo.transaction(
      fn ->
        if read_only?, do: repo.query!("SET LOCAL transaction_read_only = on")
        repo.query!("SET LOCAL statement_timeout = #{stmt_ms}")

        if search_path do
          Identifier.validate_search_path!(search_path)
          repo.query!("SET LOCAL search_path = #{search_path}")
        end

        fun.()
      end,
      timeout: timeout
    )
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def set_statement_timeout(repo, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    repo.query!("SET LOCAL statement_timeout = #{timeout_ms}")
    :ok
  end

  @impl true
  def set_search_path(repo, search_path) when is_binary(search_path) do
    Identifier.validate_search_path!(search_path)
    repo.query!("SET LOCAL search_path = #{search_path}")
    :ok
  end

  @impl true
  def format_error(%{__struct__: mod} = e) when mod == Postgrex.Error do
    pg = Map.get(e, :postgres)

    cond do
      is_map(pg) and pg[:code] == :syntax_error and is_binary(pg[:message]) ->
        "SQL syntax error: #{pg[:message]}"

      is_map(pg) and is_binary(pg[:message]) ->
        "SQL error: #{pg[:message]}"

      is_binary(Map.get(e, :message)) ->
        "SQL error: #{Map.get(e, :message)}"

      true ->
        Exception.message(e)
    end
  end

  def format_error(other), do: Default.format_error(other)

  @impl true
  def param_placeholder(idx, _var, :uuid), do: "$#{idx}::uuid"
  def param_placeholder(idx, _var, :date), do: "$#{idx}::date"
  def param_placeholder(idx, _var, :datetime), do: "$#{idx}::timestamp"
  def param_placeholder(idx, _var, :time), do: "$#{idx}::time"
  def param_placeholder(idx, _var, :number), do: "$#{idx}::numeric"
  def param_placeholder(idx, _var, :integer), do: "$#{idx}::integer"
  def param_placeholder(idx, _var, :float), do: "$#{idx}::real"
  def param_placeholder(idx, _var, :decimal), do: "$#{idx}::numeric"
  def param_placeholder(idx, _var, :boolean), do: "$#{idx}::boolean"
  def param_placeholder(idx, _var, :json), do: "$#{idx}::jsonb"
  def param_placeholder(idx, _var, :binary), do: "$#{idx}::bytea"
  def param_placeholder(idx, _var, :text), do: "$#{idx}"
  def param_placeholder(idx, _var, _type), do: "$#{idx}"

  @impl true
  def limit_offset_placeholders(limit_idx, offset_idx) do
    {"$#{limit_idx}", "$#{offset_idx}"}
  end

  @impl true
  def handled_errors, do: [Postgrex.Error]

  @impl true
  def query_language, do: "sql:postgres"

  @impl true
  def ai_context do
    {:ok,
     %{
       language: query_language(),
       example_query:
         "SELECT * FROM users WHERE created_at > NOW() - INTERVAL '7 days' ORDER BY created_at DESC LIMIT 10",
       syntax_notes:
         "Use double-quoted identifiers (\"table\", \"column\"). Arrays, JSONB, CTEs, and window functions are available. Date helpers: DATE_TRUNC, EXTRACT, NOW(), INTERVAL.",
       error_patterns: [
         %{
           pattern: ~r/relation "[^"]+" does not exist/i,
           hint:
             "The referenced table or view doesn't exist. Use list_tables() or schema-qualified names (e.g. \"public.users\")."
         },
         %{
           pattern: ~r/column "[^"]+" does not exist/i,
           hint:
             "The referenced column doesn't exist. Use describe_table() to list real columns before retrying."
         },
         %{
           pattern: ~r/syntax error at or near/i,
           hint:
             "Postgres parser rejected the query. Check quoting (double quotes for identifiers, single for strings), commas, and keyword placement."
         },
         %{
           pattern: ~r/function [a-z0-9_]+\(.*\) does not exist/i,
           hint:
             "Postgres function signature mismatch. Cast arguments explicitly (e.g. `value::integer`) or use the documented Postgres function name."
         }
       ]
     }}
  end

  @impl true
  def limit_query(statement, limit) do
    "SELECT * FROM (#{statement}) AS limited_query LIMIT #{limit}"
  end

  @impl true
  def builtin_denies(repo) do
    ms = repo.config()[:migration_source] || "schema_migrations"
    prefix = repo.config()[:migration_default_prefix] || "public"

    [
      {"pg_catalog", ~r/.*/},
      {"information_schema", ~r/.*/},
      {prefix, ms},
      {prefix, "lotus_queries"},
      {prefix, "lotus_query_visualizations"},
      {prefix, "lotus_dashboards"},
      {prefix, "lotus_dashboard_cards"},
      {prefix, "lotus_dashboard_filters"},
      {prefix, "lotus_dashboard_card_filter_mappings"}
    ]
  end

  @impl true
  def default_schemas(_repo) do
    ["public"]
  end

  @impl true
  def supports_feature?(:schema_hierarchy), do: true
  def supports_feature?(:search_path), do: true
  def supports_feature?(:make_interval), do: true
  def supports_feature?(:arrays), do: true
  def supports_feature?(:json), do: true
  def supports_feature?(_), do: false

  @impl true
  def hierarchy_label, do: "Tables"

  @impl true
  def example_query(table, schema) when is_binary(schema) do
    "SELECT value_column FROM #{schema}.#{table}"
  end

  def example_query(table, _schema) do
    "SELECT value_column FROM #{table}"
  end

  @impl true
  def builtin_schema_denies(_repo) do
    ["pg_catalog", "information_schema", "pg_toast", ~r/^pg_temp/, ~r/^pg_toast/]
  end

  @impl true
  def list_schemas(repo) do
    sql = """
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND schema_name NOT LIKE 'pg_temp_%'
      AND schema_name NOT LIKE 'pg_toast_temp_%'
    ORDER BY schema_name
    """

    %{rows: rows} = repo.query!(sql)
    Enum.map(rows, fn [schema] -> schema end)
  end

  @impl true
  def list_tables(repo, schemas, include_views?) do
    types_sql =
      if include_views?, do: "'BASE TABLE','VIEW'", else: "'BASE TABLE'"

    sql = """
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_type IN (#{types_sql})
      AND table_schema = ANY($1::text[])
    ORDER BY table_schema, table_name
    """

    %{rows: rows} = repo.query!(sql, [schemas])
    Enum.map(rows, fn [schema, table] -> {schema, table} end)
  end

  @impl true
  def describe_table(repo, schema, table) do
    # Use EXISTS for the PK check rather than LEFT JOIN against
    # key_column_usage: a column participating in multiple constraints
    # (PK + UNIQUE index, FK + unique composite, etc.) would appear once
    # per kcu row under the LEFT JOIN, duplicating the column in the
    # result.
    sql = """
    SELECT
      c.column_name,
      c.data_type,
      c.character_maximum_length,
      c.numeric_precision,
      c.numeric_scale,
      c.is_nullable,
      c.column_default,
      EXISTS (
        SELECT 1
        FROM information_schema.key_column_usage kcu
        JOIN information_schema.table_constraints tc
          ON kcu.constraint_name = tc.constraint_name
         AND kcu.table_schema = tc.table_schema
        WHERE kcu.table_schema = c.table_schema
          AND kcu.table_name = c.table_name
          AND kcu.column_name = c.column_name
          AND tc.constraint_type = 'PRIMARY KEY'
      ) AS is_primary_key
    FROM information_schema.columns c
    WHERE c.table_schema = $1 AND c.table_name = $2
    ORDER BY c.ordinal_position
    """

    %{rows: rows} = repo.query!(sql, [schema, table])

    Enum.map(rows, fn [name, type, char_len, num_prec, num_scale, nullable, default, is_pk] ->
      %{
        name: name,
        type: format_postgres_type(type, char_len, num_prec, num_scale),
        nullable: nullable == "YES",
        default: default,
        primary_key: is_pk || false
      }
    end)
  end

  @impl true
  def query_plan(repo, sql, params, opts) do
    explain_sql = "EXPLAIN (FORMAT JSON) " <> sql
    search_path = Keyword.get(opts, :search_path)

    result =
      repo.transaction(fn ->
        repo.query!("SET LOCAL transaction_read_only = on")

        if search_path do
          Identifier.validate_search_path!(search_path)
          repo.query!("SET LOCAL search_path = #{search_path}")
        end

        repo.query(explain_sql, params)
      end)
      |> case do
        {:ok, query_result} -> query_result
        {:error, err} -> {:error, err}
      end

    case result do
      {:ok, %{rows: [[json]]}} ->
        plan_text =
          case json do
            binary when is_binary(binary) -> binary
            data -> Lotus.JSON.encode!(data)
          end

        {:ok, plan_text}

      {:error, err} ->
        {:error, format_error(err)}
    end
  end

  @impl true
  def resolve_table_namespace(repo, table, schemas) do
    sql = """
    SELECT table_schema
    FROM information_schema.tables
    WHERE table_name = $1 AND table_schema = ANY($2::text[])
    ORDER BY array_position($2::text[], table_schema) NULLS LAST
    LIMIT 1
    """

    case repo.query(sql, [table, schemas]) do
      {:ok, %{rows: [[schema]]}} -> schema
      _ -> nil
    end
  end

  @impl true
  def quote_identifier(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    ~s("#{escaped}")
  end

  @impl true
  def apply_filters(%Statement{text: sql, params: params} = statement, filters) do
    {new_sql, new_params} =
      FilterInjector.apply(sql, params, filters, &quote_identifier/1, &placeholder/1)

    %{statement | text: new_sql, params: new_params}
  end

  defp placeholder(idx), do: "$#{idx}"

  @impl true
  def apply_sorts(%Statement{text: sql} = statement, sorts) do
    %{statement | text: SortInjector.apply(sql, sorts, &quote_identifier/1)}
  end

  @impl true
  def extract_accessed_resources(repo, %Statement{text: sql, params: params, meta: meta}) do
    search_path = Map.get(meta, :search_path)
    explain = "EXPLAIN (VERBOSE, FORMAT JSON) " <> sql

    result =
      repo.transaction(fn ->
        repo.query!("SET LOCAL transaction_read_only = on")

        if search_path do
          Identifier.validate_search_path!(search_path)
          repo.query!("SET LOCAL search_path = #{search_path}")
        end

        case repo.query(explain, params) do
          {:ok, %{rows: [[json]]}} ->
            try do
              json
              |> parse_explain_plan()
              |> collect_relations(MapSet.new())
            rescue
              # An EXPLAIN plan with an unexpected shape should fail preflight
              # cleanly, not crash the whole caller. Known cases: missing
              # "Plan" key, unusual list wrappers, older/newer server JSON
              # schemas.
              e -> repo.rollback("Failed to parse EXPLAIN plan: #{Exception.message(e)}")
            end

          {:error, err} ->
            repo.rollback(format_error(err))
        end
      end)

    case result do
      {:ok, relations} -> {:ok, relations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_explain_plan(json) do
    plan_data =
      case json do
        binary when is_binary(binary) -> Lotus.JSON.decode!(binary)
        data when is_list(data) or is_map(data) -> data
      end

    case plan_data do
      [first | _] -> Map.fetch!(first, "Plan")
      %{"Plan" => plan} -> plan
    end
  end

  defp collect_relations(%{"Plans" => plans} = node, acc) do
    Enum.reduce(plans, collect_relation(node, acc), &collect_relations/2)
  end

  defp collect_relations(node, acc), do: collect_relation(node, acc)

  defp collect_relation(node, acc) do
    case {node["Schema"], node["Relation Name"]} do
      {schema, rel} when is_binary(schema) and is_binary(rel) ->
        MapSet.put(acc, {schema, rel})

      _ ->
        acc
    end
  end

  defp format_postgres_type("character varying", char_len, _, _) when not is_nil(char_len),
    do: "varchar(#{char_len})"

  defp format_postgres_type("varchar", char_len, _, _) when not is_nil(char_len),
    do: "varchar(#{char_len})"

  defp format_postgres_type("character", char_len, _, _) when not is_nil(char_len),
    do: "char(#{char_len})"

  defp format_postgres_type("numeric", _, num_prec, num_scale)
       when not is_nil(num_prec) and not is_nil(num_scale),
       do: "numeric(#{num_prec},#{num_scale})"

  defp format_postgres_type("numeric", _, num_prec, _) when not is_nil(num_prec),
    do: "numeric(#{num_prec})"

  defp format_postgres_type(type, _, _, _), do: type

  @impl true
  def transform_statement(%Statement{text: sql} = statement) do
    alias Lotus.Source.Adapters.Ecto.SQL.Transformer

    new_sql =
      sql
      |> Transformer.transform_pg_intervals()
      |> Transformer.transform_wildcards(:pipe)
      |> Transformer.strip_quoted_variables()

    %{statement | text: new_sql}
  end

  @impl true
  def db_type_to_lotus_type(db_type) when is_binary(db_type) do
    lowercased = String.downcase(db_type)

    cond do
      String.ends_with?(lowercased, "[]") ->
        base_type = String.replace_suffix(lowercased, "[]", "")
        {:array, db_type_to_lotus_type(base_type)}

      lowercased == "user-defined" ->
        :enum

      true ->
        pg_scalar_type(lowercased)
    end
  end

  defp pg_scalar_type("uuid"), do: :uuid
  defp pg_scalar_type("integer"), do: :integer
  defp pg_scalar_type("bigint"), do: :integer
  defp pg_scalar_type("smallint"), do: :integer
  defp pg_scalar_type("serial"), do: :integer
  defp pg_scalar_type("bigserial"), do: :integer
  defp pg_scalar_type("real"), do: :float
  defp pg_scalar_type("double precision"), do: :float
  defp pg_scalar_type("boolean"), do: :boolean
  defp pg_scalar_type("date"), do: :date
  defp pg_scalar_type("json"), do: :json
  defp pg_scalar_type("jsonb"), do: :json
  defp pg_scalar_type("bytea"), do: :binary

  defp pg_scalar_type("numeric" <> _), do: :decimal
  defp pg_scalar_type("decimal" <> _), do: :decimal
  defp pg_scalar_type("timestamp" <> _), do: :datetime
  defp pg_scalar_type("timestamptz" <> _), do: :datetime
  defp pg_scalar_type("time" <> _), do: :time
  defp pg_scalar_type(_), do: :text

  @impl true
  def editor_config, do: EditorConfig.config()
end
