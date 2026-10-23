defmodule Lotus.Source.Adapter.Introspection do
  @moduledoc """
  Capability behaviour for browsing a source beyond its table list:
  schemas, namespace resolution, statistics, schema visibility defaults and
  the parsing and validation of qualified names.

  An adapter without it is treated as flat: one unnamed namespace,
  `"Tables"` as the hierarchy label, single-part names and permissive
  identifier validation.

  Declare it next to the core behaviour and implement every callback:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Introspection

  `Lotus.Source.Adapter` dispatches to these callbacks only when the module
  declares this behaviour. Exporting them without the declaration is not
  enough.
  """

  @doc "List all schemas in the data source."
  @callback list_schemas(state :: term()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Resolve which schema contains the named table."
  @callback resolve_table_namespace(state :: term(), table :: String.t(), schemas :: [String.t()]) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc """
  Return statistics for a relation.

  At minimum a `:row_count`; adapters may add their own keys (on-disk size,
  segment counts, a last-analyzed timestamp) and callers should tolerate
  extras.

  `Lotus.Schema.get_table_stats/3` calls this when the adapter implements
  it. Otherwise it falls back to `SELECT COUNT(*)` against the quoted
  relation name, which only makes sense for SQL sources — a non-SQL adapter
  should implement this callback rather than inherit that fallback.

  Return `{:error, :unsupported}` for an engine that exposes no such
  statistic; callers treat it as "no stats available".

  Default (when not implemented): `{:error, :unsupported}`.
  """
  @callback table_stats(state :: term(), schema :: String.t() | nil, table :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Return an estimate of the row count of the relations in `schemas`, in
  one cheap call: the engine's statistics, never a count of every table.

  A relation the engine has no estimate for is left out. Return
  `{:error, :unsupported}` for an engine with no such statistic.

  `Lotus.Schema.table_row_estimates/2` calls it, so that a caller (a model
  choosing a limit, say) knows which tables are large.

  Default (when not implemented): `{:error, :unsupported}`.
  """
  @callback table_row_estimates(state :: term(), schemas :: [String.t()]) ::
              {:ok, %{{String.t() | nil, String.t()} => non_neg_integer()}} | {:error, term()}

  @doc "Return the default schemas when none are configured."
  @callback default_schemas(state :: term()) :: [String.t()]

  @doc "Return schema patterns that should be hidden from schema listings."
  @callback builtin_schema_denies(state :: term()) :: [String.t() | Regex.t()]

  @doc ~S'Return the human-readable label for the top-level hierarchy (e.g. "Tables", "Indices").'
  @callback hierarchy_label(state :: term()) :: String.t()

  @doc """
  Parse a qualified resource name into its hierarchy components.

  The return is an ordered list: the most-coarse component first, the leaf
  last. At most two components — see "Relations are two-level" in
  `Lotus.Source.Adapter`; an engine with a deeper hierarchy flattens the
  upper levels into the first component.

  Examples across query languages:

    * SQL: `"public.users"` → `["public", "users"]`
    * Elasticsearch: `"logs-2025-01"` → `["logs-2025-01"]` (flat)
    * Mongo: `"mydb.users"` → `["mydb", "users"]`
    * BigQuery: `"proj.ds.tbl"` → `["proj.ds", "tbl"]` (flattened)

  Used by discovery UIs and AI actions to route a user-supplied name to
  the right introspection call.

  Without this capability: `{:ok, [name]}` — single-component
  interpretation.
  """
  @callback parse_qualified_name(state :: term(), name :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Validate that a string is a safe identifier for the given kind in this
  adapter's query language.

  Each adapter declares what characters are allowed:

    * Ecto SQL dialects: `[a-zA-Z_][a-zA-Z0-9_]*` for `:schema`, `:table`,
      and `:column`.
    * Elasticsearch: `:table` (index) allows hyphens and leading digits;
      `:column` (field path) allows dots for nested fields.
    * Mongo: `:column` allows dot paths for embedded document fields.

  Called from the pipeline before dispatching filter/sort column names to
  the adapter, and from AI actions that take user-supplied names.

  Without this capability: `:ok` — permissive; the adapter trusts
  its caller to validate identifiers.
  """
  @callback validate_identifier(
              state :: term(),
              kind :: :schema | :table | :column,
              value :: String.t()
            ) ::
              :ok | {:error, String.t()}

  @optional_callbacks table_stats: 3, table_row_estimates: 2
end
