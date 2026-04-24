defmodule Lotus.Source.Adapters.Ecto.Dialects.MySQL do
  @moduledoc false

  @behaviour Lotus.Source.Adapters.Ecto.Dialect
  require Logger

  alias __MODULE__.EditorConfig
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto.Dialects.Default
  alias Lotus.Source.Adapters.Ecto.SQL.FilterInjector
  alias Lotus.Source.Adapters.Ecto.SQL.SortInjector

  @default_statement_timeout_ms 5_000

  @impl true
  def source_type, do: :mysql

  @impl true
  def ecto_adapter, do: Ecto.Adapters.MyXQL

  @impl true
  def execute_in_transaction(repo, fun, opts) do
    config = parse_transaction_config(opts)

    # checkout/1 pins one pool connection for capture + setup + tx + restore;
    # without it, each query outside repo.transaction can land on a different
    # member and leave SET SESSION state stranded. Setup must run before
    # repo.transaction because MySQL rejects SET SESSION TRANSACTION inside
    # an active tx ("Transaction characteristics can't be changed…").
    repo.checkout(fn ->
      session_state = capture_session_state(repo)

      try do
        setup_transaction_session(repo, config)
        repo.transaction(fun, timeout: config.timeout)
      after
        restore_session_state(repo, session_state)
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp capture_session_state(repo) do
    prev_iso =
      case read_iso_var(repo) do
        {:ok, iso} -> iso
        _ -> nil
      end

    prev_ro =
      case repo.query("SELECT @@session.transaction_read_only") do
        {:ok, %{rows: [[ro]]}} -> ro
        _ -> nil
      end

    prev_met =
      case repo.query("SELECT @@session.max_execution_time") do
        {:ok, %{rows: [[met]]}} -> met || 0
        _ -> 0
      end

    %{isolation: prev_iso, read_only: prev_ro, max_execution_time: prev_met}
  end

  defp parse_transaction_config(opts) do
    read_only? = Keyword.get(opts, :read_only, true)

    stmt_ms =
      case Keyword.get(opts, :statement_timeout_ms, @default_statement_timeout_ms) do
        v when is_integer(v) and v >= 0 -> v
        _ -> @default_statement_timeout_ms
      end

    timeout = Keyword.get(opts, :timeout, 15_000)

    %{read_only: read_only?, statement_timeout_ms: stmt_ms, timeout: timeout}
  end

  defp setup_transaction_session(repo, config) do
    if config.read_only, do: repo.query!("SET SESSION TRANSACTION READ ONLY")
    repo.query!("SET SESSION max_execution_time = #{config.statement_timeout_ms}")
  end

  defp restore_session_state(repo, session_state) do
    # Cleanup runs in an `after` block — if a restore query itself fails
    # (connection already dropped, etc.) we swallow the secondary error so
    # the caller still sees the original exception. Matches SQLite's
    # restore_pragma_state semantics.
    restore_read_only_state(repo, session_state.read_only)
    if session_state.isolation, do: restore_iso(repo, session_state.isolation)
    restore_max_execution_time(repo, session_state.max_execution_time)
  rescue
    _ -> :ok
  end

  defp restore_read_only_state(repo, prev_ro) do
    cond do
      prev_ro in [1, "1", true] -> repo.query!("SET SESSION TRANSACTION READ ONLY")
      prev_ro in [0, "0", false] -> repo.query!("SET SESSION TRANSACTION READ WRITE")
      true -> repo.query!("SET SESSION TRANSACTION READ WRITE")
    end
  end

  defp restore_max_execution_time(repo, prev_met) do
    timeout_val = if is_integer(prev_met) and prev_met >= 0, do: prev_met, else: 0
    repo.query!("SET SESSION max_execution_time = #{timeout_val}")
  end

  defp read_iso_var(repo) do
    case repo.query("SELECT @@session.transaction_isolation") do
      {:ok, %{rows: [[iso]]}} ->
        {:ok, iso}

      {:error, _} ->
        case repo.query("SELECT @@session.tx_isolation") do
          {:ok, %{rows: [[iso]]}} -> {:ok, iso}
          {:error, err} -> {:error, err}
        end
    end
  end

  defp restore_iso(repo, iso) do
    case iso do
      "READ-COMMITTED" ->
        repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED")

      "REPEATABLE-READ" ->
        repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")

      "READ-UNCOMMITTED" ->
        repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")

      "SERIALIZABLE" ->
        repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE")

      _ ->
        :ok
    end
  end

  @impl true
  def set_statement_timeout(repo, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    repo.query!("SET SESSION max_execution_time = #{timeout_ms}")
    :ok
  end

  @impl true
  def set_search_path(_repo, _search_path), do: :ok

  @impl true
  def format_error(%{__struct__: mod} = e) when mod == MyXQL.Error do
    case e do
      %{mysql: %{code: code, message: message}} when is_integer(code) and is_binary(message) ->
        "MySQL Error (#{code}): #{message}"

      %{message: message} when is_binary(message) ->
        "MySQL Error: #{message}"

      _ ->
        Exception.message(e)
    end
  end

  def format_error(other), do: Default.format_error(other)

  @impl true
  def param_placeholder(_idx, _var, :uuid), do: "?"
  def param_placeholder(_idx, _var, :date), do: "CAST(? AS DATE)"
  def param_placeholder(_idx, _var, :datetime), do: "CAST(? AS DATETIME)"
  def param_placeholder(_idx, _var, :time), do: "CAST(? AS TIME)"
  def param_placeholder(_idx, _var, :number), do: "CAST(? AS DECIMAL)"
  def param_placeholder(_idx, _var, :integer), do: "CAST(? AS SIGNED)"
  def param_placeholder(_idx, _var, :float), do: "CAST(? AS DOUBLE)"
  def param_placeholder(_idx, _var, :decimal), do: "CAST(? AS DECIMAL)"
  def param_placeholder(_idx, _var, :boolean), do: "CAST(? AS UNSIGNED)"
  def param_placeholder(_idx, _var, :json), do: "CAST(? AS JSON)"
  def param_placeholder(_idx, _var, :binary), do: "CAST(? AS BINARY)"
  def param_placeholder(_idx, _var, :text), do: "?"
  def param_placeholder(_idx, _var, _type), do: "?"

  @impl true
  def limit_offset_placeholders(_limit_idx, _offset_idx) do
    {"?", "?"}
  end

  @impl true
  def handled_errors, do: [MyXQL.Error]

  @impl true
  def query_language, do: "sql:mysql"

  @impl true
  def ai_context do
    {:ok,
     %{
       language: query_language(),
       example_query:
         "SELECT * FROM users WHERE created_at > DATE_SUB(NOW(), INTERVAL 7 DAY) ORDER BY created_at DESC LIMIT 10",
       syntax_notes:
         "Use backtick-quoted identifiers (`table`, `column`). JSON support is limited — prefer JSON functions over direct operators. No array type. Date helpers: DATE_FORMAT, DATE_SUB, TIMESTAMPDIFF.",
       error_patterns: [
         %{
           pattern: ~r/Table '[^']+' doesn't exist/i,
           hint:
             "Table doesn't exist. Use list_tables() to see available tables or schema-qualified names (e.g. `dbname.users`)."
         },
         %{
           pattern: ~r/Unknown column '[^']+' in/i,
           hint:
             "Column doesn't exist. Use describe_table() to list real columns before retrying."
         },
         %{
           pattern: ~r/You have an error in your SQL syntax/i,
           hint:
             "MySQL parser rejected the query. Check backtick quoting, comma placement, and reserved-word usage."
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
    database = repo.config()[:database]

    base_denies = [
      {"information_schema", ~r/.*/},
      {"mysql", ~r/.*/},
      {"performance_schema", ~r/.*/},
      {"sys", ~r/.*/},
      {nil, ms},
      {nil, "lotus_queries"},
      {nil, "lotus_query_visualizations"},
      {nil, "lotus_dashboards"},
      {nil, "lotus_dashboard_cards"},
      {nil, "lotus_dashboard_filters"},
      {nil, "lotus_dashboard_card_filter_mappings"}
    ]

    if database do
      base_denies ++
        [
          {database, ms},
          {database, "lotus_queries"},
          {database, "lotus_query_visualizations"},
          {database, "lotus_dashboards"},
          {database, "lotus_dashboard_cards"},
          {database, "lotus_dashboard_filters"},
          {database, "lotus_dashboard_card_filter_mappings"}
        ]
    else
      base_denies
    end
  end

  @impl true
  def default_schemas(repo) do
    database = repo.config()[:database] || "public"
    [database]
  end

  @impl true
  def supports_feature?(:schema_hierarchy), do: false
  def supports_feature?(:search_path), do: false
  def supports_feature?(:make_interval), do: false
  def supports_feature?(:arrays), do: false
  def supports_feature?(:json), do: true
  def supports_feature?(_), do: false

  @impl true
  def hierarchy_label, do: "Tables"

  @impl true
  def example_query(table, _schema) do
    "SELECT value_column FROM #{table}"
  end

  @impl true
  def builtin_schema_denies(_repo) do
    ["information_schema", "mysql", "performance_schema", "sys"]
  end

  @impl true
  def list_schemas(repo) do
    sql = """
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
    ORDER BY schema_name
    """

    %{rows: rows} = repo.query!(sql)
    Enum.map(rows, fn [schema] -> schema end)
  end

  @impl true
  def list_tables(repo, schemas, include_views?) do
    if schemas == [] do
      []
    else
      types_sql =
        if include_views?, do: "'BASE TABLE','VIEW'", else: "'BASE TABLE'"

      placeholders = Enum.map_join(1..length(schemas), ",", fn _ -> "?" end)

      sql = """
      SELECT table_schema, table_name
      FROM information_schema.tables
      WHERE table_type IN (#{types_sql})
        AND table_schema IN (#{placeholders})
      ORDER BY table_schema, table_name
      """

      %{rows: rows} = repo.query!(sql, schemas)
      Enum.map(rows, fn [schema, table] -> {schema, table} end)
    end
  end

  @impl true
  def describe_table(repo, schema, table) do
    # COLUMN_TYPE carries the full declaration (e.g. "tinyint(1)", "binary(16)",
    # "varchar(255)", "decimal(10,2)") that db_type_to_lotus_type/1 pattern-matches
    # on. DATA_TYPE strips the precision/length, which would silently make the
    # "tinyint(1) -> :boolean" and "binary(16) -> :uuid" mappings unreachable.
    sql = """
    SELECT
      c.column_name,
      c.column_type,
      c.is_nullable,
      c.column_default,
      IF(c.column_key = 'PRI', 1, 0) as is_primary_key
    FROM information_schema.columns c
    WHERE c.table_schema = ? AND c.table_name = ?
    ORDER BY c.ordinal_position
    """

    %{rows: rows} = repo.query!(sql, [schema, table])

    Enum.map(rows, fn [name, type, nullable, default, is_pk] ->
      %{
        name: name,
        type: type,
        nullable: nullable == "YES",
        default: default,
        primary_key: is_pk == 1
      }
    end)
  end

  @impl true
  def query_plan(repo, sql, params, _opts) do
    explain_sql = "EXPLAIN FORMAT=JSON " <> sql

    case repo.query(explain_sql, params) do
      {:ok, %{rows: [[json]]}} ->
        {:ok, json}

      {:error, err} ->
        {:error, format_error(err)}
    end
  end

  @impl true
  def resolve_table_namespace(_repo, _table, []), do: nil

  def resolve_table_namespace(repo, table, schemas) do
    placeholders = Enum.map_join(1..length(schemas), ",", fn _ -> "?" end)

    sql = """
    SELECT table_schema
    FROM information_schema.tables
    WHERE table_name = ? AND table_schema IN (#{placeholders})
    ORDER BY FIELD(table_schema, #{placeholders})
    LIMIT 1
    """

    params = [table] ++ schemas ++ schemas

    case repo.query(sql, params) do
      {:ok, %{rows: [[schema]]}} -> schema
      _ -> nil
    end
  end

  @impl true
  def quote_identifier(identifier) do
    escaped = String.replace(identifier, "`", "``")
    "`#{escaped}`"
  end

  @impl true
  def apply_filters(%Statement{text: sql, params: params} = statement, filters) do
    {new_sql, new_params} =
      FilterInjector.apply(sql, params, filters, &quote_identifier/1, fn _idx -> "?" end)

    %{statement | text: new_sql, params: new_params}
  end

  @impl true
  def apply_sorts(%Statement{text: sql} = statement, sorts) do
    %{statement | text: SortInjector.apply(sql, sorts, &quote_identifier/1)}
  end

  alias Lotus.Source.Adapters.Ecto, as: EctoHelpers

  @impl true
  def extract_accessed_resources(repo, %Statement{text: sql, params: params, meta: meta}) do
    opts = Map.to_list(meta)
    alias_map = EctoHelpers.parse_alias_map(sql)
    explain = "EXPLAIN FORMAT=JSON " <> sql

    # Route through execute_in_transaction so EXPLAIN runs under
    # SET SESSION TRANSACTION READ ONLY + SET SESSION max_execution_time.
    # MySQL's SESSION setting only takes effect at the next START TRANSACTION,
    # so the SETs must happen before repo.transaction — which is what
    # execute_in_transaction already guarantees.
    result =
      execute_in_transaction(
        repo,
        fn ->
          case repo.query(explain, params) do
            {:ok, %{rows: [[json]]}} ->
              explain_rels =
                json
                |> Lotus.JSON.decode!()
                |> collect_mysql_relations(MapSet.new())
                |> MapSet.to_list()
                |> Enum.map(fn {schema, table_name} ->
                  {schema, EctoHelpers.resolve_alias(table_name, alias_map)}
                end)
                |> Enum.reject(fn {_schema, name} -> is_nil(name) end)

              sql_rels = extract_tables_from_sql(sql)
              choose_relations(explain_rels, sql_rels, sql) |> MapSet.new()

            {:error, err} ->
              repo.rollback(format_error(err))
          end
        end,
        opts
      )

    case result do
      {:ok, relations} -> {:ok, relations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_mysql_relations(%{"query_block" => query_block}, acc) do
    collect_query_block(query_block, acc)
  end

  defp collect_mysql_relations(data, acc) when is_list(data) do
    Enum.reduce(data, acc, &collect_mysql_relations/2)
  end

  defp collect_mysql_relations(data, acc) when is_map(data) do
    case Map.get(data, "query_block") do
      nil -> acc
      query_block -> collect_query_block(query_block, acc)
    end
  end

  defp collect_mysql_relations(_, acc), do: acc

  defp collect_query_block(%{"table" => table_info}, acc) when is_map(table_info) do
    case Map.get(table_info, "table_name") do
      table_name when is_binary(table_name) ->
        schema = Map.get(table_info, "schema")
        MapSet.put(acc, {schema, table_name})

      _ ->
        acc
    end
  end

  defp collect_query_block(%{"nested_loop" => nested_loop}, acc) when is_list(nested_loop) do
    Enum.reduce(nested_loop, acc, fn item, acc_inner ->
      collect_query_block(item, acc_inner)
    end)
  end

  defp collect_query_block(data, acc) when is_map(data) do
    Enum.reduce(data, acc, fn {_key, value}, acc_inner ->
      collect_mysql_relations(value, acc_inner)
    end)
  end

  defp collect_query_block(_, acc), do: acc

  defp extract_tables_from_sql(sql) do
    table_regex =
      ~r/(?:FROM|JOIN)\s+(?:(`?)([a-zA-Z_][a-zA-Z0-9_]*)\1\.)?(`?)([a-zA-Z_][a-zA-Z0-9_]*)\3(?:\s+(?:AS\s+)?[a-zA-Z_][a-zA-Z0-9_]*)?/i

    Regex.scan(table_regex, sql)
    |> Enum.map(fn
      [_, _, schema, _, table] when schema != "" -> {schema, table}
      [_, "", "", _, table] -> {nil, table}
      # Regex future-proofing: if the capture groups change (e.g. someone adds
      # an optional alias capture), unmatched shapes fall through to nil and
      # are filtered out rather than crashing preflight.
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp choose_relations(explain_rels, sql_rels, sql) do
    if should_use_sql_relations?(explain_rels, sql),
      do: sql_rels,
      else: explain_rels
  end

  defp should_use_sql_relations?(explain_rels, sql) do
    Enum.empty?(explain_rels) or
      Enum.all?(explain_rels, fn {_, name} -> String.length(name) <= 4 end) or
      String.contains?(sql, "information_schema") or
      String.contains?(sql, "performance_schema") or
      String.contains?(sql, "mysql.") or
      String.contains?(sql, "sys.")
  end

  @impl true
  def transform_statement(%Statement{text: sql} = statement) do
    alias Lotus.Source.Adapters.Ecto.SQL.Transformer

    new_sql =
      sql
      |> Transformer.transform_wildcards(:concat_fn)
      |> Transformer.strip_quoted_variables()

    %{statement | text: new_sql}
  end

  @impl true
  def db_type_to_lotus_type(db_type) do
    mysql_scalar_type(String.downcase(db_type))
  end

  defp mysql_scalar_type("char(36)"), do: :uuid
  defp mysql_scalar_type("char(32)"), do: :uuid
  defp mysql_scalar_type("binary(16)"), do: :uuid
  defp mysql_scalar_type("tinyint(1)"), do: :boolean
  defp mysql_scalar_type("date"), do: :date
  defp mysql_scalar_type("json"), do: :json

  defp mysql_scalar_type("int" <> _), do: :integer
  defp mysql_scalar_type("bigint" <> _), do: :integer
  defp mysql_scalar_type("smallint" <> _), do: :integer
  defp mysql_scalar_type("tinyint" <> _), do: :integer
  defp mysql_scalar_type("decimal" <> _), do: :decimal
  defp mysql_scalar_type("numeric" <> _), do: :decimal
  defp mysql_scalar_type("float" <> _), do: :float
  defp mysql_scalar_type("double" <> _), do: :float
  defp mysql_scalar_type("datetime" <> _), do: :datetime
  defp mysql_scalar_type("timestamp" <> _), do: :datetime
  defp mysql_scalar_type(_), do: :text

  @impl true
  def editor_config, do: EditorConfig.config()
end
