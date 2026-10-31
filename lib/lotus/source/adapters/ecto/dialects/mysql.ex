defmodule Lotus.Source.Adapters.Ecto.Dialects.MySQL do
  @moduledoc """
  MySQL dialect for `Lotus.Source.Adapters.Ecto`.

  MySQL has no schema-within-database concept, so databases serve as
  namespaces. Query plans come from `EXPLAIN FORMAT=JSON`, and the
  statement timeout is applied as `max_execution_time`. There is no search
  path, so `set_search_path/2` is not implemented.

  Read alongside `Lotus.Source.Adapters.Ecto.Dialect` when writing a dialect
  for another SQL engine — this module is the reference implementation.
  """

  @behaviour Lotus.Source.Adapters.Ecto.Dialect

  alias __MODULE__.EditorConfig
  alias __MODULE__.Relations
  alias Lotus.Query.Filter
  alias Lotus.Query.Statement
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Source.Adapters.Ecto, as: EctoHelpers
  alias Lotus.Source.Adapters.Ecto.Dialects.Default
  alias Lotus.SQL.FilterInjector
  alias Lotus.SQL.SortInjector

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
  def limit_query(%Statement{body: body} = statement, limit)
      when is_integer(limit) and limit > 0 do
    %{statement | body: "SELECT * FROM (\n#{body}\n) AS limited_query LIMIT #{limit}"}
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
      {nil, "lotus_dashboard_card_filter_mappings"},
      {nil, "lotus_schedules"},
      {nil, "lotus_schedule_runs"}
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
          {database, "lotus_dashboard_card_filter_mappings"},
          {database, "lotus_schedules"},
          {database, "lotus_schedule_runs"}
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
  def supports_feature?(:dynamic_options), do: true
  def supports_feature?(_), do: false

  @impl true
  def hierarchy_label, do: "Tables"

  @impl true
  def example_query(table, _schema) do
    "SELECT value_column FROM #{table}"
  end

  # Named locks (held by the pooled connection), files, waits on
  # replication, and sleeps max_execution_time may not bound.
  @impl true
  def denied_functions do
    [
      "get_lock",
      "release_lock",
      "release_all_locks",
      "load_file",
      "sleep",
      "benchmark",
      "master_pos_wait",
      "source_pos_wait",
      "wait_for_executed_gtid_set",
      "sys_exec",
      "sys_eval"
    ]
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
      IF(c.column_key = 'PRI', 1, 0) as is_primary_key,
      c.column_comment
    FROM information_schema.columns c
    WHERE c.table_schema = ? AND c.table_name = ?
    ORDER BY c.ordinal_position
    """

    %{rows: rows} = repo.query!(sql, [schema, table])
    references = foreign_keys(repo, schema, table)

    Enum.map(rows, fn [name, type, nullable, default, is_pk, comment] ->
      %{
        name: name,
        type: type,
        nullable: nullable == "YES",
        default: default,
        primary_key: is_pk == 1,
        comment: if(comment in [nil, ""], do: nil, else: comment),
        references: Map.get(references, name)
      }
    end)
  end

  defp foreign_keys(repo, schema, table) do
    sql = """
    SELECT k.column_name, k.referenced_table_schema, k.referenced_table_name,
           k.referenced_column_name
    FROM information_schema.key_column_usage k
    WHERE k.table_schema = ? AND k.table_name = ?
      AND k.referenced_table_name IS NOT NULL
    ORDER BY k.constraint_name, k.ordinal_position
    """

    %{rows: rows} = repo.query!(sql, [schema, table])

    Enum.reduce(rows, %{}, fn [column, ref_schema, ref_table, ref_column], acc ->
      Map.put_new(acc, column, %{schema: ref_schema, table: ref_table, column: ref_column})
    end)
  end

  # TABLE_ROWS: exact for MyISAM, the storage engine's estimate for InnoDB.
  @impl true
  def table_row_estimates(_repo, []), do: %{}

  def table_row_estimates(repo, schemas) do
    placeholders = Enum.map_join(schemas, ", ", fn _ -> "?" end)

    sql = """
    SELECT table_schema, table_name, table_rows
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE' AND table_schema IN (#{placeholders})
    """

    %{rows: rows} = repo.query!(sql, schemas)

    for [schema, table, rows] <- rows, is_integer(rows), into: %{}, do: {{schema, table}, rows}
  end

  # In a read-only transaction, as preflight's EXPLAIN runs.
  @impl true
  def query_plan(repo, %Statement{body: sql, params: params}, opts) do
    explain_sql = "EXPLAIN FORMAT=JSON " <> sql

    execute_in_transaction(
      repo,
      fn ->
        case repo.query(explain_sql, params) do
          {:ok, %{rows: [[json]]}} -> json
          {:error, err} -> repo.rollback(format_error(err))
        end
      end,
      Keyword.take(opts, [:read_only, :statement_timeout_ms, :timeout])
    )
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
  def supported_filter_operators, do: Filter.operators()

  @impl true
  def apply_filters(%Statement{body: sql, params: params} = statement, filters) do
    {new_sql, new_params} =
      FilterInjector.apply(sql, params, filters, &quote_identifier/1, fn _idx -> "?" end)

    %{statement | body: new_sql, params: new_params}
  end

  @impl true
  def apply_sorts(%Statement{body: sql} = statement, sorts) do
    %{statement | body: SortInjector.apply(sql, sorts, &quote_identifier/1)}
  end

  # `EXPLAIN`, `DESCRIBE` and `DESC` describe a table (`DESCRIBE t`) or how
  # a statement reads its tables, and `SHOW COLUMNS` and `SHOW INDEX` a
  # table: each is checked by what it describes. Any other `SHOW` names no
  # table of its own and is not checked, as before.
  @name ~S/(`(?:[^`]|``)+`|[\w$]+)/
  @explained ~r/\A\s*(?:EXPLAIN|DESCRIBE|DESC)\b((?:\s+(?:EXTENDED|PARTITIONS|ANALYZE)\b|\s*FORMAT\s*=\s*\w+)*)\s*(.*)\z/is
  @statement_starts ~w(select with table values insert update delete replace)

  defp show_table_regex do
    Regex.compile!(
      "\\A\\s*SHOW\\s+(?:EXTENDED\\s+)?(?:FULL\\s+)?(?:COLUMNS|FIELDS|INDEX|INDEXES|KEYS)\\s+" <>
        "(?:FROM|IN)\\s+(?:#{@name}\\s*\\.\\s*)?#{@name}(?:\\s+(?:FROM|IN)\\s+#{@name})?",
      "is"
    )
  end

  @impl true
  def needs_preflight?(%Statement{body: sql}) when is_binary(sql) do
    text = statement_text(sql)
    not Regex.match?(~r/\A\s*SHOW\b/i, text) or Regex.match?(show_table_regex(), text)
  end

  def needs_preflight?(_statement), do: true

  @impl true
  def extract_accessed_resources(repo, %Statement{body: sql} = statement) when is_binary(sql) do
    with {:ok, relations} <- accessed(repo, statement),
         do: {:ok, fold_case(repo, relations)}
  end

  # MySQL reads its system schemas' names in any case, and a table's too
  # when `lower_case_table_names` folds them, while visibility rules match
  # a name as given: those names are also checked as the server stores
  # them.
  @system_schemas ~w(information_schema mysql performance_schema sys)

  defp fold_case(repo, relations) do
    fold_tables? =
      case repo.query("SELECT @@lower_case_table_names") do
        {:ok, %{rows: [[mode]]}} -> mode != 0
        _ -> true
      end

    relations
    |> Enum.flat_map(fn {schema, table} = relation ->
      down = schema && String.downcase(schema)
      schema = if down in @system_schemas, do: down, else: schema
      folded = if fold_tables?, do: [{down, String.downcase(table)}], else: []
      [relation, {schema, table} | folded]
    end)
    |> MapSet.new()
  end

  defp accessed(repo, %Statement{body: sql} = statement) do
    text = statement_text(sql)

    cond do
      match = Regex.run(@explained, text) ->
        explained(repo, statement, List.last(match))

      match = Regex.run(show_table_regex(), text) ->
        {:ok, MapSet.new([shown_table(tl(match))])}

      true ->
        statement_relations(repo, statement)
    end
  end

  defp explained(repo, statement, inner) do
    first = inner |> String.trim_leading() |> String.downcase()

    cond do
      String.starts_with?(first, "(") or
          Enum.any?(@statement_starts, &Regex.match?(~r/\A#{&1}\b/, first)) ->
        accessed(repo, %{statement | body: inner})

      Regex.match?(~r/\Afor\b/, first) ->
        {:error, "Lotus can't tell which tables EXPLAIN FOR CONNECTION reads"}

      match = Regex.run(~r/\A\s*(?:#{@name}\s*\.\s*)?#{@name}/s, inner) ->
        {:ok, MapSet.new([table_path(tl(match))])}

      true ->
        {:error, "Lotus can't tell which table the statement describes"}
    end
  end

  # `SHOW COLUMNS FROM t FROM db` names the table's database after it.
  defp shown_table([schema, table, database]) when schema in [nil, ""],
    do: {unquote_name(database), unquote_name(table)}

  defp shown_table([schema, table | _]), do: table_path([schema, table])

  defp table_path(["", table]), do: {nil, unquote_name(table)}
  defp table_path([schema, table]), do: {unquote_name(schema), unquote_name(table)}

  defp unquote_name("`" <> _ = raw),
    do: raw |> String.slice(1..-2//1) |> String.replace("``", "`")

  defp unquote_name(raw), do: raw

  defp statement_text(sql),
    do: EctoHelpers.statement_text(sql, Profile.for_language(query_language()))

  defp statement_relations(repo, %Statement{body: sql, params: params, meta: meta}) do
    opts = Map.to_list(meta)
    read = Relations.read(sql)
    explain = "EXPLAIN FORMAT=JSON " <> sql

    # Route through execute_in_transaction so EXPLAIN runs under
    # SET SESSION TRANSACTION READ ONLY + SET SESSION max_execution_time.
    # MySQL's SESSION setting only takes effect at the next START TRANSACTION,
    # so the SETs must happen before repo.transaction — which is what
    # execute_in_transaction already guarantees.
    #
    # The relations are the union of what EXPLAIN names (by alias, without a
    # schema, mapped back through the statement) and what the statement
    # reads, so neither can drop a table the other sees.
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
                |> Enum.reject(fn {_schema, name} -> is_nil(name) end)
                |> Enum.flat_map(&Relations.resolve(&1, read))

              MapSet.new(read.tables ++ explain_rels)

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

  # Every table the plan names, wherever it sits: under a query block's
  # nested loop, beside it (`select_list_subqueries`,
  # `optimized_away_subqueries`) or in a table's `attached_subqueries`.
  defp collect_mysql_relations(data, acc) when is_map(data) do
    acc =
      case data do
        %{"table_name" => name} when is_binary(name) ->
          MapSet.put(acc, {Map.get(data, "schema"), name})

        _ ->
          acc
      end

    Enum.reduce(data, acc, fn {_key, value}, acc -> collect_mysql_relations(value, acc) end)
  end

  defp collect_mysql_relations(data, acc) when is_list(data),
    do: Enum.reduce(data, acc, &collect_mysql_relations/2)

  defp collect_mysql_relations(_data, acc), do: acc

  # The tables the statement's text reads, as `{schema, table}`; see
  # `MySQL.Relations`.
  @doc false
  def extract_tables_from_sql(sql), do: Relations.read(sql).tables

  @impl true
  def transform_statement(%Statement{body: sql} = statement) do
    alias Lotus.SQL.Transformer

    profile = Profile.for_language(query_language())

    new_sql =
      sql
      |> Transformer.transform_wildcards(:concat_fn, profile)
      |> Transformer.strip_quoted_variables(profile)

    %{statement | body: new_sql}
  end

  @impl true
  def db_type_to_lotus_type(db_type) do
    mysql_scalar_type(String.downcase(db_type))
  end

  # Only binary(16) holds a UUID as the 16 bytes `:uuid` casts to. A char(36)
  # or char(32) column holds text (a UUID's string or hex form, or anything
  # else that long, such as an MD5 digest), so a value compared with it is
  # bound as the text it is.
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
