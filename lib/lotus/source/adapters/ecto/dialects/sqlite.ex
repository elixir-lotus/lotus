defmodule Lotus.Source.Adapters.Ecto.Dialects.SQLite3 do
  @moduledoc false

  @behaviour Lotus.Source.Adapters.Ecto.Dialect

  require Logger

  alias __MODULE__.EditorConfig
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto.Dialects.Default
  alias Lotus.Source.Adapters.Ecto.SQL.FilterInjector
  alias Lotus.Source.Adapters.Ecto.SQL.SortInjector

  @impl true
  def source_type, do: :sqlite

  @impl true
  def ecto_adapter, do: Ecto.Adapters.SQLite3

  @impl true
  def execute_in_transaction(repo, fun, opts) do
    read_only? = Keyword.get(opts, :read_only, true)
    timeout = Keyword.get(opts, :timeout, 15_000)

    # checkout/1 pins one pool connection for setup + tx + restore;
    # without it, PRAGMA query_only (connection-scoped) could be set on one
    # pool member and never restored, leaving it stuck in read-only mode.
    repo.checkout(fn ->
      {pragma_supported?, prev_state} = setup_read_only_pragma(repo, read_only?)

      try do
        repo.transaction(fun, timeout: timeout)
      after
        restore_pragma_state(repo, pragma_supported?, prev_state)
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp setup_read_only_pragma(_repo, false), do: {false, nil}

  defp setup_read_only_pragma(repo, true) do
    check_and_set_pragma(repo)
  rescue
    error in [Exqlite.Error] ->
      msg = error.message || Exception.message(error)

      if msg =~ "no such pragma" or msg =~ "unknown pragma" do
        log_pragma_warning()
        {false, nil}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp check_and_set_pragma(repo) do
    case repo.query("PRAGMA query_only") do
      {:ok, %{rows: [[prev]]}} ->
        repo.query!("PRAGMA query_only = ON")
        {true, prev}

      _ ->
        {false, nil}
    end
  end

  defp log_pragma_warning do
    Logger.warning("""
    SQLite version does not support PRAGMA query_only.
    Consider opening the DB in read-only mode
    (e.g., database=...&mode=ro or database=...&immutable=1).
    """)
  end

  defp restore_pragma_state(_repo, false, _prev_state), do: :ok

  defp restore_pragma_state(repo, true, prev_state) do
    restore = if prev_state in [0, 1], do: prev_state, else: 0
    repo.query!("PRAGMA query_only = #{restore}")
  rescue
    _ -> :ok
  end

  @impl true
  def set_statement_timeout(_repo, _timeout_ms), do: :ok

  @impl true
  def set_search_path(_repo, _search_path), do: :ok

  @impl true
  def format_error(%{__struct__: mod} = e) when mod == Exqlite.Error do
    "SQLite Error: " <> (Map.get(e, :message) || Exception.message(e))
  end

  def format_error(other), do: Default.format_error(other)

  @impl true
  def param_placeholder(_idx, _var, _type), do: "?"

  @impl true
  def limit_offset_placeholders(_limit_idx, _offset_idx) do
    {"?", "?"}
  end

  @impl true
  def handled_errors, do: [Exqlite.Error]

  @impl true
  def query_language, do: "sql:sqlite"

  @impl true
  def ai_context do
    {:ok,
     %{
       language: query_language(),
       example_query:
         "SELECT * FROM users WHERE created_at > datetime('now', '-7 days') ORDER BY created_at DESC LIMIT 10",
       syntax_notes:
         "Use double-quoted identifiers (\"table\", \"column\"). Dynamic typing — column types are hints, not enforced. Date helpers: date(), datetime(), strftime(). Older versions lack window functions; prefer subqueries.",
       error_patterns: [
         %{
           pattern: ~r/no such table/i,
           hint:
             "Table doesn't exist. SQLite is schema-flat — use list_tables() to see what's available."
         },
         %{
           pattern: ~r/no such column/i,
           hint:
             "Column doesn't exist. Use describe_table() to list real columns before retrying."
         },
         %{
           pattern: ~r/near ".*": syntax error/i,
           hint:
             "SQLite parser rejected the query near a specific token. Check quoting and keyword order."
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

    [
      {nil, ~r/^sqlite_/},
      {nil, ms},
      {nil, "lotus_queries"},
      {nil, "lotus_query_visualizations"},
      {nil, "lotus_dashboards"},
      {nil, "lotus_dashboard_cards"},
      {nil, "lotus_dashboard_filters"},
      {nil, "lotus_dashboard_card_filter_mappings"}
    ]
  end

  @impl true
  def default_schemas(_repo) do
    []
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
    []
  end

  @impl true
  def list_schemas(_repo) do
    []
  end

  @impl true
  def list_tables(repo, _schemas, _include_views?) do
    query = """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """

    result = repo.query!(query)
    Enum.map(result.rows, fn [table_name] -> {nil, table_name} end)
  end

  @impl true
  def describe_table(repo, _schema, table_name) do
    # Use quote_identifier/1 (double-quote + escaped internal quotes) rather
    # than the strict identifier validator — list_tables/3 returns SQLite
    # names verbatim from sqlite_master, which accepts legal names the
    # validator rejects (e.g. "2024_events" starts with a digit).
    # Quoted identifiers remain injection-safe via the escape-doubling in
    # quote_identifier/1.
    query = "PRAGMA table_info(#{quote_identifier(table_name)})"

    result = repo.query!(query)

    Enum.map(result.rows, fn row ->
      [_cid, name, type, notnull, default, pk] = row

      %{
        name: name,
        type: type,
        nullable: notnull == 0,
        default: default,
        primary_key: pk == 1
      }
    end)
  end

  @impl true
  def query_plan(repo, sql, params, _opts) do
    explain_sql = "EXPLAIN QUERY PLAN " <> sql

    case repo.query(explain_sql, params) do
      {:ok, %{rows: rows}} ->
        plan_text =
          Enum.map_join(rows, "\n", fn row -> Enum.join(row, " | ") end)

        {:ok, plan_text}

      {:error, err} ->
        {:error, format_error(err)}
    end
  end

  @impl true
  def resolve_table_namespace(_repo, _table, _schemas) do
    nil
  end

  @impl true
  def quote_identifier(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    ~s("#{escaped}")
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
    explain = "EXPLAIN QUERY PLAN " <> sql

    # Route through execute_in_transaction so EXPLAIN runs under
    # PRAGMA query_only = ON with capture/restore around the tx.
    # PRAGMA query_only is connection-scoped in SQLite, so setting it
    # inline without restoration would poison the next connection checkout.
    result =
      execute_in_transaction(
        repo,
        fn ->
          case repo.query(explain, params) do
            {:ok, %{rows: rows}} -> parse_explain_rows(rows, alias_map)
            {:error, err} -> repo.rollback(format_error(err))
          end
        end,
        opts
      )

    case result do
      {:ok, relations} -> {:ok, relations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_explain_rows(rows, alias_map) do
    rows
    |> Enum.map(fn row -> Enum.join(row, " ") end)
    |> Enum.flat_map(&extract_relations_from_text/1)
    |> Enum.map(&EctoHelpers.resolve_alias(&1, alias_map))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{nil, &1})
    |> MapSet.new()
  end

  defp extract_relations_from_text(text) do
    cond do
      Regex.match?(
        ~r/\b(?:SCAN|SEARCH)\s+TABLE\s+("[^"]+"|[A-Za-z0-9_]+)\s+AS\s+("[^"]+"|[A-Za-z0-9_]+)/,
        text
      ) ->
        for [_, base, _alias] <-
              Regex.scan(
                ~r/\b(?:SCAN|SEARCH)\s+TABLE\s+("[^"]+"|[A-Za-z0-9_]+)\s+AS\s+("[^"]+"|[A-Za-z0-9_]+)/,
                text
              ) do
          EctoHelpers.normalize_ident(base)
        end

      Regex.match?(~r/\b(?:SCAN|SEARCH)\s+TABLE\s+("[^"]+"|[A-Za-z0-9_]+)/, text) ->
        for [_, base] <-
              Regex.scan(~r/\b(?:SCAN|SEARCH)\s+TABLE\s+("[^"]+"|[A-Za-z0-9_]+)/, text) do
          EctoHelpers.normalize_ident(base)
        end

      Regex.match?(~r/\b(?:SCAN|SEARCH)\s+("[^"]+"|[A-Za-z0-9_]+)/, text) ->
        for [_, name] <- Regex.scan(~r/\b(?:SCAN|SEARCH)\s+("[^"]+"|[A-Za-z0-9_]+)/, text) do
          EctoHelpers.normalize_ident(name)
        end

      true ->
        []
    end
  end

  @impl true
  def transform_statement(%Statement{text: sql} = statement) do
    alias Lotus.Source.Adapters.Ecto.SQL.Transformer

    new_sql =
      sql
      |> Transformer.transform_wildcards(:pipe)
      |> Transformer.strip_quoted_variables()

    %{statement | text: new_sql}
  end

  # SQLite accepts any declared type string; prefix-match on the type name so
  # parameterized declarations (DECIMAL(10,2), VARCHAR(255)) and family
  # variants (BIGINT, FLOAT, BOOLEAN) map to their Lotus type instead of
  # silently falling through to :text.
  #
  # Order matters: longer prefixes must come before shorter ones that would
  # also match (e.g. INTEGER before INT, DATETIME before DATE).
  @type_prefixes [
    {"INTEGER", :integer},
    {"BIGINT", :integer},
    {"SMALLINT", :integer},
    {"MEDIUMINT", :integer},
    {"TINYINT", :integer},
    {"INT", :integer},
    {"REAL", :float},
    {"FLOAT", :float},
    {"DOUBLE", :float},
    {"DECIMAL", :decimal},
    {"NUMERIC", :decimal},
    {"BOOLEAN", :boolean},
    {"DATETIME", :datetime},
    {"TIMESTAMP", :datetime},
    {"DATE", :date},
    {"TIME", :time},
    {"BLOB", :binary}
  ]

  @impl true
  def db_type_to_lotus_type(db_type) do
    up = String.upcase(db_type)

    # VARCHAR/CHAR/TEXT/CLOB and unknown types fall through to :text.
    # SQLite stores UUIDs as TEXT (no native UUID type).
    Enum.find_value(@type_prefixes, :text, fn {prefix, type} ->
      if String.starts_with?(up, prefix), do: type
    end)
  end

  @impl true
  def editor_config, do: EditorConfig.config()
end
