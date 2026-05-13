defmodule Lotus.Source.Adapters.Ecto.Dialect do
  @moduledoc false

  alias Lotus.Query.Statement

  @type repo :: Ecto.Repo.t()

  # ---------------------------------------------------------------------------
  # Required callbacks — Session management
  # ---------------------------------------------------------------------------

  @callback execute_in_transaction(repo, (-> any()), keyword()) :: {:ok, any()} | {:error, any()}
  @callback set_statement_timeout(repo, non_neg_integer()) :: :ok | no_return()
  @callback set_search_path(repo, String.t()) :: :ok | no_return()

  # ---------------------------------------------------------------------------
  # Required callbacks — Error handling
  # ---------------------------------------------------------------------------

  @callback format_error(any()) :: String.t()
  @callback handled_errors() :: [module()]

  # ---------------------------------------------------------------------------
  # Required callbacks — SQL generation
  # ---------------------------------------------------------------------------

  @callback quote_identifier(String.t()) :: String.t()

  @callback param_placeholder(index :: pos_integer(), var :: String.t(), type :: atom() | nil) ::
              String.t()

  @callback limit_offset_placeholders(
              limit_index :: pos_integer(),
              offset_index :: pos_integer()
            ) ::
              {limit_placeholder :: String.t(), offset_placeholder :: String.t()}

  @callback apply_filters(
              statement :: Statement.t(),
              filters :: [Lotus.Query.Filter.t()]
            ) ::
              Statement.t()

  @callback apply_sorts(statement :: Statement.t(), sorts :: [Lotus.Query.Sort.t()]) ::
              Statement.t()

  @callback query_plan(repo, sql :: String.t(), params :: list(), opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Required callbacks — Safety & visibility
  # ---------------------------------------------------------------------------

  @callback builtin_denies(repo) ::
              [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]

  @callback builtin_schema_denies(repo) :: [String.t() | Regex.t()]

  @callback default_schemas(repo) :: [String.t()]

  # ---------------------------------------------------------------------------
  # Required callbacks — Introspection
  # ---------------------------------------------------------------------------

  @callback list_schemas(repo) :: [String.t()]

  @callback list_tables(repo, schemas :: [String.t()], include_views? :: boolean()) ::
              [{schema :: String.t() | nil, table :: String.t()}]

  @callback describe_table(repo, schema :: String.t() | nil, table :: String.t()) ::
              [
                %{
                  name: String.t(),
                  type: String.t(),
                  nullable: boolean(),
                  default: String.t() | nil,
                  primary_key: boolean()
                }
              ]

  @callback resolve_table_namespace(repo, table :: String.t(), schemas :: [String.t()]) ::
              String.t() | nil

  # ---------------------------------------------------------------------------
  # Required callbacks — Source identity
  # ---------------------------------------------------------------------------

  @callback source_type() :: :postgres | :mysql | :sqlite | :other | atom()
  @callback ecto_adapter() :: module() | nil
  @callback query_language() :: String.t()
  @callback limit_query(statement :: String.t(), limit :: pos_integer()) :: String.t()

  # ---------------------------------------------------------------------------
  # Optional callbacks — Source identity
  # ---------------------------------------------------------------------------

  @callback editor_config() :: %{
              required(:language) => String.t(),
              required(:keywords) => [String.t()],
              required(:types) => [String.t()],
              required(:functions) => [%{name: String.t(), detail: String.t(), args: String.t()}],
              required(:context_boundaries) => [String.t()],
              optional(:dialect_spec) => Lotus.Source.Adapter.dialect_spec(),
              optional(:context_schema) => Lotus.Source.Adapter.context_schema()
            }

  @callback supports_feature?(feature :: atom()) :: boolean()
  @callback hierarchy_label() :: String.t()
  @callback example_query(table :: String.t(), schema :: String.t() | nil) :: String.t()

  # ---------------------------------------------------------------------------
  # Optional callbacks — Resource extraction
  # ---------------------------------------------------------------------------

  @doc """
  Extract the set of tables/relations a statement will access.

  Used by `Lotus.Preflight` to check visibility rules before execution.
  Return `{:ok, MapSet}` with `{schema, table}` tuples, `{:error, reason}`,
  or `{:unrestricted, reason}` when the dialect cannot enforce visibility
  at this layer.

  Default (when not implemented): `{:unrestricted, ...}`.
  """
  @callback extract_accessed_resources(repo, statement :: Statement.t()) ::
              {:ok, MapSet.t({String.t() | nil, String.t()})}
              | {:error, term()}
              | {:unrestricted, String.t()}

  # ---------------------------------------------------------------------------
  # Optional callbacks — Statement transformation & type mapping
  # ---------------------------------------------------------------------------

  @doc """
  Rewrite the statement before variables are extracted and bound.

  Fires in `Lotus.Storage.Query.to_sql_params/2` before `{{var}}` placeholders
  are resolved. Use for dialect-specific syntax rewrites (wildcard handling,
  INTERVAL, CONCAT vs `||`, etc.). Return the rewritten statement.

  Default (when not implemented): statement unchanged.
  """
  @callback transform_statement(statement :: Statement.t()) :: Statement.t()

  @doc """
  Whether the statement needs the visibility preflight check before execution.

  Used by the Ecto adapter's built-in `needs_preflight?/2` default to skip
  introspection statements (`EXPLAIN`, `SHOW`, `PRAGMA`) that don't access
  visible relations. Dialects may override with a language-specific check.

  Default (when not implemented): `true` (always preflight).
  """
  @callback needs_preflight?(statement :: Statement.t()) :: boolean()

  @doc """
  Map a database-specific column type string to a Lotus internal type atom.

  Each dialect knows its own type system (e.g. Postgres `uuid`, MySQL `char(36)`,
  SQLite `INTEGER`).

  Default (when not implemented): `:text`.
  """
  @callback db_type_to_lotus_type(db_type :: String.t()) :: atom()

  @doc """
  Return the adapter-shaped AI context for this dialect.

  Supplies the four `Lotus.Source.Adapter.ai_context_map` keys —
  `:language`, `:example_query`, `:syntax_notes`, `:error_patterns` —
  with dialect-specific content. The built-in SQL dialects populate
  Postgres / MySQL / SQLite quirks here.

  Default (when not implemented): generic-SQL context synthesized from
  `query_language/0`, with an empty error-pattern list.
  """
  @callback ai_context() :: {:ok, Lotus.Source.Adapter.ai_context_map()} | {:error, term()}

  @optional_callbacks [
    supports_feature?: 1,
    hierarchy_label: 0,
    example_query: 2,
    extract_accessed_resources: 2,
    transform_statement: 1,
    needs_preflight?: 1,
    db_type_to_lotus_type: 1,
    editor_config: 0,
    ai_context: 0
  ]
end
