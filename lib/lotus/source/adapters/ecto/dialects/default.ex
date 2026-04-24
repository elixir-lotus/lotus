defmodule Lotus.Source.Adapters.Ecto.Dialects.Default do
  @moduledoc """
  Last-resort fallback dialect for Ecto repos whose underlying Ecto adapter
  has no specialized Lotus dialect (Postgres / MySQL / SQLite).

  **Not a base to extend from.** This module is a degraded, SQL-family-shaped
  fallback so that Lotus doesn't crash when it encounters an unknown Ecto
  adapter. It is not a neutral "default" template. When it's used instead of
  a proper per-dialect module, the following safety and observability features
  silently degrade:

    * `execute_in_transaction/3` runs a plain `repo.transaction/2` with no
      read-only guard. Callers' `read_only: true` intent is not enforced at
      the database level.
    * `set_statement_timeout/2` is a no-op, so user-configured statement
      timeouts have no effect.
    * `extract_accessed_resources/4` is not implemented, so
      `Lotus.Preflight.authorize/4` short-circuits to `:ok` — visibility rules
      are **not** checked against the tables the query touches.
    * `list_schemas/1`, `list_tables/3`, and `describe_table/3` return
      empty lists — the schema browser will be blank.
    * `default_schemas/1` returns `["public"]` (Postgres-specific) and
      `builtin_denies/1` is a shotgun union of Postgres + MySQL + SQLite
      system-schema patterns. Patterns that don't apply to the target
      database are inert but misleading.

  ## Adding a new SQL dialect (Snowflake, Tds, ClickHouse-via-Ecto, etc.)

  Don't rely on this fallback. Implement a dedicated dialect module under
  `Lotus.Source.Adapters.Ecto.Dialects.*` that fulfills the
  `Lotus.Source.Adapters.Ecto.Dialect` behaviour, then wire it up via
  `use Lotus.Source.Adapters.Ecto, dialect: <YourDialect>` in a new adapter
  module.

  ## Building a non-Ecto adapter (HTTP API, Elasticsearch, etc.)

  This module is in the wrong part of the tree for you. Implement
  `Lotus.Source.Adapter` directly and register via `:source_adapters`.
  """

  @behaviour Lotus.Source.Adapters.Ecto.Dialect

  require Logger

  alias __MODULE__.EditorConfig
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto.SQL.FilterInjector
  alias Lotus.Source.Adapters.Ecto.SQL.SortInjector

  @impl true
  def source_type, do: :other

  @impl true
  def ecto_adapter, do: nil

  @impl true
  def execute_in_transaction(repo, fun, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    if Keyword.get(opts, :read_only, true) do
      warn_read_only_unsupported(repo)
    end

    repo.transaction(fun, timeout: timeout)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Logs once per {dialect, repo} per BEAM node. Warning fires when the caller
  # asked for a read-only transaction but this fallback dialect can't enforce
  # it at the DB level — visible signal that a proper Dialect implementation
  # is needed for the repo's Ecto adapter.
  defp warn_read_only_unsupported(repo) do
    key = {__MODULE__, :read_only_warned, repo}

    case :persistent_term.get(key, :none) do
      :warned ->
        :ok

      :none ->
        :persistent_term.put(key, :warned)

        Logger.warning(
          "Lotus.Source.Adapters.Ecto.Dialects.Default cannot enforce read-only " <>
            "transactions for #{inspect(repo)} (Ecto adapter: #{inspect(repo.__adapter__())}). " <>
            "Queries will run against a writable connection. Implement a " <>
            "Lotus.Source.Adapters.Ecto.Dialect for this adapter to restore the guarantee."
        )
    end
  end

  @impl true
  def set_statement_timeout(_repo, _ms), do: :ok

  @impl true
  def set_search_path(_repo, _path), do: :ok

  @impl true
  # Note on clause order: the %{__exception__: true} pattern matches every
  # exception struct (including DBConnection.EncodeError and ArgumentError),
  # so anything that delegates to Exception.message/1 must come first. The
  # binary clause handles already-formatted error strings; the catch-all
  # covers atoms/tuples/other adapter-raw errors.
  def format_error(%{__exception__: true} = e), do: Exception.message(e)
  def format_error(msg) when is_binary(msg), do: msg
  def format_error(other), do: "Database Error: #{inspect(other)}"

  @impl true
  def param_placeholder(_idx, _var, _type), do: "?"

  @impl true
  def limit_offset_placeholders(_limit_idx, _offset_idx) do
    {"?", "?"}
  end

  @impl true
  def handled_errors, do: []

  @impl true
  def query_language, do: "sql"

  @impl true
  def limit_query(statement, limit) do
    "SELECT * FROM (#{statement}) AS limited_query LIMIT #{limit}"
  end

  @impl true
  def builtin_denies(_repo), do: Adapter.builtin_denies()

  @impl true
  def default_schemas(_repo) do
    ["public"]
  end

  @impl true
  def supports_feature?(_), do: false

  @impl true
  def hierarchy_label, do: "Tables"

  @impl true
  def example_query(table, _schema) do
    "SELECT value_column FROM #{table}"
  end

  @impl true
  def builtin_schema_denies(_repo), do: Adapter.builtin_schema_denies()

  @impl true
  def list_schemas(_repo) do
    []
  end

  @impl true
  def list_tables(_repo, _schemas, _include_views?) do
    []
  end

  @impl true
  def describe_table(_repo, _schema, _table) do
    []
  end

  @impl true
  def query_plan(_repo, _sql, _params, _opts) do
    {:error, "EXPLAIN not supported for this database adapter"}
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

  @impl true
  def editor_config, do: EditorConfig.config()

  # Fallback for unknown Ecto dialects — every DB type maps to :text. A proper
  # dialect should implement this with its own type-family mapping.
  @impl true
  def db_type_to_lotus_type(_db_type), do: :text
end
