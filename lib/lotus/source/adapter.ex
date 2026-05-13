defmodule Lotus.Source.Adapter do
  @moduledoc """
  Behaviour and struct for database adapters in Lotus.

  An adapter wraps a data source behind a uniform interface. Instead of passing
  raw Ecto.Repo modules throughout the pipeline, consumers work with an
  `%Adapter{}` struct that carries:

    * `name`        — a human-readable identifier (e.g. `"main"`, `"warehouse"`)
    * `module`      — the module implementing this behaviour
    * `state`       — opaque connection state managed by the adapter
    * `source_type` — an atom identifying the database kind (`:postgres`, `:mysql`, etc.)

  ## Implementing an adapter

  Define a module that uses `@behaviour Lotus.Source.Adapter` and implements all
  required callbacks. Callbacks fall into several groups:

    * **Query execution** — `execute_query/4`, `transaction/3`
    * **Introspection** — `list_schemas/1`, `list_tables/3`, `describe_table/3`,
      `resolve_table_namespace/3`
    * **SQL generation** — `quote_identifier/2`, `query_plan/4`
    * **Pipeline** — `transform_statement/2`, `transform_bound_query/3`,
      `apply_filters/3`, `apply_sorts/3`, `apply_pagination/3`,
      `needs_preflight?/2`, `sanitize_query/3`,
      `substitute_variable/5`, `substitute_list_variable/5`,
      `validate_statement/3`, `extract_accessed_resources/2`
    * **Name & operator validation** — `parse_qualified_name/2`,
      `validate_identifier/3`, `supported_filter_operators/1`
    * **Safety & visibility** — `builtin_denies/1`, `builtin_schema_denies/1`,
      `default_schemas/1`
    * **Lifecycle** — `health_check/1`, `disconnect/1`
    * **Error handling** — `format_error/2`, `handled_errors/1`
    * **Source identity** — `source_type/1`, `supports_feature?/2`

  ## Pipeline Statement contract

  All pipeline callbacks operate on a `%Lotus.Query.Statement{}` struct that
  carries the adapter-native payload (`:text`, opaque term), `:params`, and
  adapter-specific `:meta`. Adapters return a new statement with the relevant
  field updated — the pipeline is a series of pure `statement -> statement`
  transforms.

  Introspection callbacks consistently return `{:ok, result} | {:error, reason}`
  tuples so callers can handle failures uniformly.

  ## Dispatch helpers

  This module provides convenience functions that accept an `%Adapter{}` struct
  and delegate to the underlying module, passing `state` where needed:

      adapter = %Adapter{name: "main", module: MyPostgres, state: conn, source_type: :postgres}

      Adapter.execute_query(adapter, "SELECT 1", [], [])
      Adapter.list_schemas(adapter)
      Adapter.quote_identifier(adapter, "users")
  """

  alias Lotus.Query.Filter
  alias Lotus.Query.Statement

  @type source_type :: :postgres | :mysql | :sqlite | :other | atom()

  @type column_def :: %{
          name: String.t(),
          type: String.t(),
          nullable: boolean(),
          default: String.t() | nil,
          primary_key: boolean()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          module: module(),
          state: term(),
          source_type: source_type()
        }

  @enforce_keys [:name, :module, :source_type]
  defstruct [:name, :module, :state, :source_type]

  # ---------------------------------------------------------------------------
  # Callbacks — Query Execution
  # ---------------------------------------------------------------------------

  @doc """
  Execute a prepared statement against the data source.

  This is the driver boundary: adapters receive the adapter-native statement
  payload (SQL text for Ecto, a JSON body for Elasticsearch, a DSL AST for
  other engines) together with any bound `params`, and return the usual
  `{columns, rows, num_rows}` result shape so core can assemble a
  `%Lotus.Result{}`.

  ## Optional `:total_count` — inline count strategy

  When the caller requested `count: :exact` via pagination and the adapter
  can compute the pre-pagination row total as a side-effect of running the
  main query (e.g. Elasticsearch's `hits.total.value` with
  `track_total_hits: true`), include `:total_count` in the result map:

      {:ok, %{
        columns: [...],
        rows: [...],
        num_rows: N,
        total_count: T    # pre-pagination total; nil if unavailable
      }}

  Adapters without a cheap inline count should omit the key and use
  `apply_pagination/3` + `:count_spec` to compute the total via a separate
  query. See the pagination callback for the full precedence rule.
  """
  @callback execute_query(state :: term(), sql :: term(), params :: list(), opts :: keyword()) ::
              {:ok,
               %{
                 :columns => [String.t()],
                 :rows => [[term()]],
                 :num_rows => non_neg_integer(),
                 optional(:total_count) => non_neg_integer() | nil
               }}
              | {:error, term()}

  @doc "Execute a function within a transaction."
  @callback transaction(state :: term(), fun :: (term() -> any()), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  # ---------------------------------------------------------------------------
  # Callbacks — Introspection
  # ---------------------------------------------------------------------------

  @doc "List all schemas in the data source."
  @callback list_schemas(state :: term()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "List tables (and optionally views) in the given schemas."
  @callback list_tables(state :: term(), schemas :: [String.t()], opts :: keyword()) ::
              {:ok, [{schema :: String.t() | nil, table :: String.t()}]} | {:error, term()}

  @doc "Return column definitions for a specific table."
  @callback describe_table(state :: term(), schema :: String.t() | nil, table :: String.t()) ::
              {:ok, [column_def()]} | {:error, term()}

  @doc "Resolve which schema contains the named table."
  @callback resolve_table_namespace(state :: term(), table :: String.t(), schemas :: [String.t()]) ::
              {:ok, String.t() | nil} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Callbacks — SQL Generation
  # ---------------------------------------------------------------------------

  @doc "Quote a SQL identifier (column, table, schema name) using source-specific syntax."
  @callback quote_identifier(state :: term(), String.t()) :: String.t()

  @doc "Apply filters to the statement, returning a new statement with the filters baked in."
  @callback apply_filters(state :: term(), statement :: Statement.t(), filters :: list()) ::
              Statement.t()

  @doc "Apply sorts to the statement, returning a new statement with the sort order baked in."
  @callback apply_sorts(state :: term(), statement :: Statement.t(), sorts :: list()) ::
              Statement.t()

  @doc """
  Return an execution plan for a query.

  For SQL-prepared adapters, this is typically the output of the dialect's
  EXPLAIN variant (e.g. `EXPLAIN` on Postgres, `EXPLAIN QUERY PLAN` on
  SQLite, `EXPLAIN FORMAT=JSON` on MySQL) — a human-readable or structured
  string describing how the server will execute the query.

  Non-SQL adapters whose engines don't expose a plan (or don't expose one
  cheaply) may legitimately return `{:ok, nil}` or `{:error, :unsupported}`;
  Lotus callers treat both as "no plan available" without surfacing an
  error to the user.
  """
  @callback query_plan(state :: term(), sql :: String.t(), params :: list(), opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Callbacks — Pipeline (Query Processing)
  # ---------------------------------------------------------------------------

  @doc """
  Validate that a statement is safe to execute.

  Called before execution to enforce single-statement and deny-list rules.
  Return `:ok` to allow or `{:error, reason}` to block.

  ## Options

    * `:read_only` — when `true`, block write operations

  Default (when not implemented): `:ok` (allow all statements).
  """
  @callback sanitize_query(state :: term(), statement :: Statement.t(), opts :: keyword()) ::
              :ok | {:error, String.t()}

  @doc """
  Rewrite the statement after variable substitution.

  Pipeline position: fires inside `Lotus.execute_with_options/7` **after**
  `{{var}}` placeholders have been resolved into `statement.params`, and
  **before** `apply_filters`, `apply_sorts`, and `apply_pagination` mutate
  the statement.

  Use when you need access to the bound parameter values — for example, to
  inline values into `statement.text` for a transport that can't carry
  prepared-statement parameters, or to apply a transformation that depends on
  the bound values.

  The statement payload is whatever the adapter understands (SQL text, JSON
  DSL, AST, etc.); this callback is language-agnostic. For rewrites that only
  need the raw statement text (before variables are bound), implement
  `transform_statement/2` instead.

  Default (when not implemented): statement unchanged.
  """
  @callback transform_bound_query(
              state :: term(),
              statement :: Statement.t(),
              opts :: keyword()
            ) ::
              Statement.t()

  @doc """
  Extract the set of tables/relations a statement will access.

  Used by `Lotus.Preflight` to check visibility rules before execution.
  Return `{:ok, MapSet}` with `{schema, table}` tuples, `{:error, reason}`,
  or `{:unrestricted, reason}` when visibility cannot be enforced at this
  layer (the adapter signals Lotus to consult the host-app opt-in gate
  before allowing the statement through).

  Default (when not implemented): `{:unrestricted, "adapter does not implement extract_accessed_resources/2"}`.
  """
  @callback extract_accessed_resources(state :: term(), statement :: Statement.t()) ::
              {:ok, MapSet.t({String.t() | nil, String.t()})}
              | {:error, term()}
              | {:unrestricted, String.t()}

  @typedoc """
  Optional count-query description placed in `statement.meta[:count_spec]` by
  `apply_pagination/3` when the caller requested `count: :exact`. Plain data:
  `:query` is the count payload (SQL text, JSON DSL, whatever the adapter's
  language calls "count this result set"), and `:params` are its bound
  parameters. Lotus core runs this through the same adapter the paginated
  statement ran through — the adapter does not need to remember its own
  identity.
  """
  @type count_spec :: %{query: term(), params: list()}

  @doc """
  Rewrite a statement to return a single page of rows, and optionally record
  a count query for the full result set.

  Pipeline position: fires **after** `apply_filters/3` and `apply_sorts/3`,
  so the input statement already has any filters and sorts applied.

  ## Opts

    * `:limit` (required) — page size
    * `:offset` — page offset (default: `0`)
    * `:count` — `:none` (default) or `:exact`. When `:exact`, the adapter
      picks one of two strategies to surface the pre-pagination total:

      **Strategy A — inline count.** The adapter arranges for its main
      query to return the total as a side-effect (e.g. Elasticsearch's
      `track_total_hits: true`, MongoDB's `$facet`). `execute_query/4`
      returns the count via the optional `:total_count` key in its result
      map. The adapter does *not* set `:count_spec` in `statement.meta`.

      **Strategy B — separate count query.** The adapter places a
      `count_spec` in `statement.meta[:count_spec]`; Lotus core runs it
      through the same adapter after the main query. Standard for SQL
      adapters (a `SELECT count(*) FROM ...` around the filtered query).

      Adapters pick one — not both. If both are present, Strategy A wins
      (the inline count from the main query is authoritative; the
      count_spec is not run).
    * `:search_path` — forwarded by callers that care about schema isolation

  ## Return

  A paginated `%Statement{}`. When counting is requested, the returned
  statement's `:meta` map holds `:count_spec` (a `count_spec()` value).
  Lotus core assembles any surrounding metadata (original adapter struct,
  search_path, etc.) from its own scope.

  Default (when not implemented): statement unchanged, no pagination.
  """
  @callback apply_pagination(
              state :: term(),
              statement :: Statement.t(),
              pagination_opts :: keyword()
            ) ::
              Statement.t()

  @doc """
  Whether a statement needs the visibility preflight check before execution.

  Implementors return `false` for read-only introspection statements that do
  not access visible relations (e.g. SQL `EXPLAIN`, `SHOW`, `PRAGMA`) and
  `true` for everything else. Lotus core runs preflight when this callback
  returns `true` and skips it when `false`.

  Default (when not implemented): `true` (always preflight — safer).
  """
  @callback needs_preflight?(state :: term(), statement :: Statement.t()) :: boolean()

  @doc """
  Substitute a `{{var_name}}` placeholder in the statement with the given
  value, returning a new statement.

  Adapters own their substitution strategy because it depends on the query
  language:

    * SQL (prepared-statement) drivers add a placeholder (`$1`, `?`, ...) to
      `statement.text`, append the value to `statement.params`, and leave
      binding to the driver.
    * JSON / DSL adapters (Elasticsearch, Mongo) inline the value as a
      properly-escaped literal inside `statement.text`.

  `value` has already been type-cast by Lotus core. `type` is the resolved
  Lotus internal type atom (e.g. `:integer`, `:uuid`) — adapters that care
  about type-specific placeholders use it; others may ignore it.

  Return `{:error, :unsupported}` when the adapter has no `{{var}}` mental
  model (e.g. an adapter whose statement is a fully pre-built term and does
  not accept user variables at all).

  **Security note.** Adapters that inline values are the only defense
  against injection at this layer. Never interpolate raw strings —
  delegate to `Lotus.JSON.encode!/1` or an equivalent escaper for the target
  language.

  Default (when not implemented): `{:error, :unsupported}`.
  """
  @callback substitute_variable(
              state :: term(),
              statement :: Statement.t(),
              var_name :: String.t(),
              value :: term(),
              type :: atom() | nil
            ) ::
              {:ok, Statement.t()} | {:error, term()}

  @doc """
  Substitute a `{{var_name}}` list-variable placeholder with the given list
  of values, returning a new statement.

  Adapters choose the natural shape for their query language: SQL expands
  into a placeholder group (`$1, $2, $3`); JSON DSLs emit a JSON array.
  Callers must not rely on the substituted text form beyond "the variable
  has been expanded into the statement's native list representation".

  `values` is a non-empty list of already-cast values. `type` is the
  resolved Lotus internal type atom shared by all list elements.

  Default (when not implemented): `{:error, :unsupported}`.
  """
  @callback substitute_list_variable(
              state :: term(),
              statement :: Statement.t(),
              var_name :: String.t(),
              values :: [term()],
              type :: atom() | nil
            ) ::
              {:ok, Statement.t()} | {:error, term()}

  @doc """
  Validate that a statement can be parsed and prepared by the data source
  without executing it.

  SQL-prepared adapters typically implement this via `EXPLAIN` (the server
  parses + type-checks the query without running it). Non-SQL engines
  might use a `_validate` endpoint (Elasticsearch) or return `:ok`
  unconditionally as a trust-on-execute fallback.

  Called by lotus_web's "validate before run" feature and AI actions that
  want to sanity-check a draft before surfacing it to the user. Callers
  are responsible for neutralizing any unbound `{{var}}` placeholders
  before calling this — adapters see the statement as-is.

  Default (when not implemented): `:ok` — trust-on-execute; errors surface
  at run time.
  """
  @callback validate_statement(
              state :: term(),
              statement :: Statement.t(),
              opts :: keyword()
            ) ::
              :ok | {:error, term()}

  @doc """
  Parse a qualified resource name into its hierarchy components.

  The return is an ordered list: the most-coarse component first, the leaf
  last. Component count should match `hierarchy_label/1` depth.

  Examples across query languages:

    * SQL: `"public.users"` → `["public", "users"]`
    * Elasticsearch: `"logs-2025-01"` → `["logs-2025-01"]` (flat)
    * Mongo: `"mydb.users"` → `["mydb", "users"]`

  Used by discovery UIs and AI actions to route a user-supplied name to
  the right introspection call.

  Default (when not implemented): `{:ok, [name]}` — single-component
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

  Default (when not implemented): `:ok` — permissive; the adapter trusts
  its caller to validate identifiers.
  """
  @callback validate_identifier(
              state :: term(),
              kind :: :schema | :table | :column,
              value :: String.t()
            ) ::
              :ok | {:error, String.t()}

  @doc """
  Return the `Lotus.Query.Filter` operators this adapter's `apply_filters/3`
  can handle.

  Core validates filter operators against this list before dispatching.
  Unsupported operators raise `Lotus.UnsupportedOperatorError` rather than
  silently degrading. lotus_web reads this through
  `Lotus.Source.supported_filter_operators/1` to gate the filter operator
  dropdown per source.

  Default (when not implemented): all operators in `Lotus.Query.Filter.operators/0`
  — the permissive choice, which existing adapters inherit without change.
  Adapters that cannot implement the full set must override and declare
  their actual support.
  """
  @callback supported_filter_operators(state :: term()) :: [atom()]

  # ---------------------------------------------------------------------------
  # Callbacks — Safety & Visibility
  # ---------------------------------------------------------------------------

  @doc "Return built-in deny rules for system tables (list of `{schema_pattern, table_pattern}` tuples)."
  @callback builtin_denies(state :: term()) ::
              [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]

  @doc "Return schema patterns that should be hidden from schema listings."
  @callback builtin_schema_denies(state :: term()) :: [String.t() | Regex.t()]

  @doc "Return the default schemas when none are configured."
  @callback default_schemas(state :: term()) :: [String.t()]

  # ---------------------------------------------------------------------------
  # Callbacks — Lifecycle
  # ---------------------------------------------------------------------------

  @doc "Check that the data source is reachable."
  @callback health_check(state :: term()) :: :ok | {:error, term()}

  @doc "Disconnect from the data source and release resources."
  @callback disconnect(state :: term()) :: :ok

  # ---------------------------------------------------------------------------
  # Callbacks — Error Handling
  # ---------------------------------------------------------------------------

  @doc """
  Format a data-source error into a human-readable string.

  Adapters translate driver-specific exceptions (e.g. `Postgrex.Error`,
  `MyXQL.Error`, or a non-SQL engine's error struct) into a user-facing
  message. Called from `Lotus.Runner` when the execution phase raises.
  """
  @callback format_error(state :: term(), any()) :: String.t()

  @doc """
  Return the exception modules this adapter knows how to format.

  Used by `Lotus.Runner`'s rescue clause to match a raised exception
  against the adapter's `format_error/2`. Returning the narrow set the
  adapter actually handles lets unrelated exceptions propagate.
  """
  @callback handled_errors(state :: term()) :: [module()]

  # ---------------------------------------------------------------------------
  # Callbacks — Source Identity
  # ---------------------------------------------------------------------------

  @doc "Return the source type atom (e.g. `:postgres`, `:mysql`)."
  @callback source_type(state :: term()) :: source_type()

  @doc "Whether this adapter supports a given feature."
  @callback supports_feature?(state :: term(), atom()) :: boolean()

  @doc """
  Return the query language identifier for this source.

  Used by the AI pipeline, editor integrations, and `:schema_hierarchy` UI
  affordances to know what kind of statement text this source accepts.
  Examples:

    * `"sql:postgres"`, `"sql:mysql"`, `"sql:sqlite"` for SQL-prepared adapters
    * `"elasticsearch:json"` for an Elasticsearch DSL adapter
    * `"mongo:aggregation"` for a MongoDB aggregation pipeline adapter
  """
  @callback query_language(state :: term()) :: String.t()

  @typedoc """
  Per-AI-feature capability declaration. Adapters use this to declare
  which AI features they actually support — `Lotus.AI.supports?/2`
  reads it directly to let UIs gate per-source button visibility.

    * `true` — feature supported.
    * `{false, reason}` — feature unsupported; the reason is surfaced
      to users. For untrusted adapters, reasons are replaced with a
      generic fallback at the dispatch layer.

  Default (when the `:capabilities` key is absent from `ai_context_map`):
  all three features `true` — existing adapters inherit the permissive
  behavior without needing to declare anything.
  """
  @type ai_capability :: true | {false, String.t()}

  @type ai_capabilities :: %{
          generation: ai_capability(),
          optimization: ai_capability(),
          explanation: ai_capability()
        }

  @typedoc """
  Structured, bounded context an adapter supplies to the AI pipeline.

  Fixed keys; free-form fields are length-capped at the dispatch layer
  to bound blast radius from a compromised or noisy adapter. See
  `Lotus.Source.Adapter.ai_context/1` dispatch for exact limits.

  The optional `:capabilities` map declares per-feature AI support.
  """
  @type ai_context_map :: %{
          required(:language) => String.t(),
          required(:example_query) => String.t(),
          required(:syntax_notes) => String.t(),
          required(:error_patterns) => [%{pattern: Regex.t(), hint: String.t()}],
          optional(:capabilities) => ai_capabilities()
        }

  @doc """
  Return the structured context the AI pipeline uses when generating
  queries for this source.

  The returned map has fixed keys:

    * `:language` — query-language identifier (same shape as
      `query_language/1`: `"sql:postgres"`, `"elasticsearch:json"`, ...).
      Must match a constrained character set; violating identifiers are
      replaced with `"unknown"` at the dispatch layer.
    * `:example_query` — one concrete example statement showing the
      adapter's syntax idioms. Capped at 2048 bytes.
    * `:syntax_notes` — short prose covering quoting, reserved words,
      or dialect-specific pitfalls. Capped at 1024 bytes.
    * `:error_patterns` — up to 20 `%{pattern: Regex.t(), hint: binary}`
      entries. When a query fails, the first matching `:pattern` feeds
      its `:hint` back into the LLM so it can self-correct.

  Return `{:error, :ai_not_supported}` (or any `{:error, term}`) to opt
  the source out of AI generation entirely — `Lotus.AI.generate_query_with_context/1`
  surfaces a clean "AI not supported for source" error instead of
  hallucinating syntax the adapter can't run.

  **Security note.** Untrusted adapters can influence LLM output through
  `:syntax_notes` and `:error_patterns`. Host apps opt adapters into the
  full context via `config :lotus, :trusted_source_adapters`. Untrusted
  adapters see only `:language` plumbed to the prompt; free-form fields
  are discarded.

  Default (when not implemented): `{:error, :ai_not_supported}` — the
  adapter is opted out of AI.
  """
  @callback ai_context(state :: term()) :: {:ok, ai_context_map()} | {:error, term()}

  @doc """
  Return a statement safe to pass to `query_plan/4` for optimization
  analysis.

  Callers (`Lotus.AI.QueryOptimizer`) run this first so the adapter can
  resolve any `[[ ... ]]` optional clauses and replace `{{var}}`
  placeholders with language-appropriate null-ish literals (`NULL` for
  SQL, `null` for JSON DSLs). The returned statement's `:text` must be
  syntactically valid in the adapter's language without bound params
  so the engine's EXPLAIN / profile endpoint can parse it.

  Default (when not implemented): `{:error, :unsupported}` — the caller
  skips optimization analysis for this adapter.
  """
  @callback prepare_for_analysis(state :: term(), statement :: Statement.t()) ::
              {:ok, Statement.t()} | {:error, term()}

  @doc """
  Wrap a raw statement string with a source-specific row limit.

  **SQL-shaped callback.** The `statement` argument is the raw statement
  text (typically SQL) and the result is the same text wrapped with a
  single-page `LIMIT` / `TOP` / `FETCH FIRST` clause (exact syntax varies
  per dialect). Used by the UI's "preview this query" affordance to cap
  returned rows without touching the underlying query.

  Non-SQL adapters whose languages don't have a textual limit clause may
  return the input unchanged — Lotus core treats the callback as best-
  effort and does not depend on it for correctness.
  """
  @callback limit_query(state :: term(), statement :: String.t(), limit :: pos_integer()) ::
              String.t()

  @doc ~S'Return the human-readable label for the top-level hierarchy (e.g. "Tables", "Indices").'
  @callback hierarchy_label(state :: term()) :: String.t()

  @doc "Return an example query string for placeholder text in the query editor."
  @callback example_query(state :: term(), table :: String.t(), schema :: String.t() | nil) ::
              String.t()

  # ---------------------------------------------------------------------------
  # Callbacks — Pluggable Registration
  # ---------------------------------------------------------------------------

  @doc "Whether this adapter can handle the given data source entry (e.g. a repo module)."
  @callback can_handle?(term()) :: boolean()

  @doc "Wrap a raw data source entry into an `%Adapter{}` struct."
  @callback wrap(name :: String.t(), term()) :: t()

  # ---------------------------------------------------------------------------
  # Callbacks — Query Transformation & Type Mapping
  # ---------------------------------------------------------------------------

  @doc """
  Rewrite the statement before variables are extracted and bound.

  Pipeline position: fires inside `Lotus.Storage.Query.to_sql_params/2`
  **before** `{{var}}` placeholders are extracted from `statement.text` and
  before any value is bound. The statement's `:params` is `[]` at this point.

  Use for language-specific syntax normalization of the stored template
  (e.g., wildcard rewriting, quoted-variable stripping). Works for any
  query language: SQL text, JSON DSL, Cypher, etc.

  For rewrites that need access to the resolved param values (post-binding),
  implement `transform_bound_query/3` instead.

  Default (when not implemented): statement unchanged.
  """
  @callback transform_statement(state :: term(), statement :: Statement.t()) :: Statement.t()

  @doc "Map a database column type string to a Lotus internal type atom."
  @callback db_type_to_lotus_type(state :: term(), db_type :: String.t()) :: atom()

  @typedoc """
  Optional SQL tokenizer spec, passed through verbatim (camelCased) to
  CodeMirror 6's `SQLDialect.define()` so external SQL adapters can reach
  tokenization parity with the built-in PG / MySQL Lezer grammars.

  Field names mirror `@codemirror/lang-sql`'s `SQLDialectSpec` — see
  `assets/node_modules/@codemirror/lang-sql/dist/index.d.ts` in
  `lotus_web` for authoritative semantics.
  """
  @type dialect_spec :: %{
          optional(:identifier_quotes) => String.t(),
          optional(:operator_chars) => String.t(),
          optional(:hash_comments) => boolean(),
          optional(:slash_comments) => boolean(),
          optional(:double_quoted_strings) => boolean(),
          optional(:double_dollar_quoted_strings) => boolean(),
          optional(:backslash_escapes) => boolean(),
          optional(:space_after_dashes) => boolean(),
          optional(:case_insensitive_identifiers) => boolean(),
          optional(:builtin) => String.t(),
          optional(:char_set_casts) => boolean(),
          optional(:plsql_quoting_mechanism) => boolean(),
          optional(:unquoted_bit_literals) => boolean(),
          optional(:treat_bits_as_bytes) => boolean(),
          optional(:special_var) => String.t()
        }

  @typedoc """
  Structural JSON DSL schema used by `lotus_web`'s `JsonDslCompletion` to
  offer parent-aware completions (e.g., only `must`/`should`/`filter`
  inside Elasticsearch's `bool` block; field names from the schema
  inside `match`/`term`/`range`).

  * `:root` — valid top-level keys.
  * `:children` — per-parent-key rules. Values are either a list of valid
    child keys, or one of the marker atoms `:fields` (use schema field
    names), `:array_of_query` (array element objects accept the same
    keys as `"query"`), `:named_aggregation` (user-named bucket — no
    key suggestions), or `:range_operators` (grandparent lookup for ES
    range-style operators).
  * `:value_literals` — fixed value-position completions keyed by
    immediate key (e.g., `"order" => ["asc", "desc"]`).
  """
  @type context_schema :: %{
          required(:root) => [String.t()],
          required(:children) => %{
            String.t() => [String.t()] | atom() | [{String.t(), atom()}]
          },
          optional(:value_literals) => %{String.t() => [String.t()]}
        }

  @doc """
  Return editor configuration (keywords, types, functions) for the adapter.

  ## Shape

  Required fields:

    * `:language` — query-language identifier (e.g. `"sql:postgres"`,
      `"json:elasticsearch"`). Drives CodeMirror language selection.
    * `:keywords`, `:types` — flat lists feeding the "complete any
      keyword anywhere" fallback (used when `:context_schema` is
      absent) and the AI prompt pipeline.
    * `:functions` — `%{name, detail, args}` entries for signature help.
    * `:context_boundaries` — SQL-only; ignored for JSON DSLs.

  Optional fields:

    * `:dialect_spec` — SQL tokenizer options, forwarded verbatim to
      CodeMirror's `SQLDialect.define()`. Only meaningful for SQL
      languages; adapters on a built-in CM6 dialect (Postgres, MySQL,
      SQLite, MSSQL, MariaSQL, Cassandra, PLSQL) can omit this and
      get the built-in grammar.
    * `:context_schema` — JSON DSL structural completion schema. Drives
      parent-aware autocomplete (e.g., Elasticsearch's `bool` →
      `must`/`should`/`filter`). Omit for SQL adapters; for JSON DSL
      adapters, omitting it degrades the editor to flat keyword
      suggestions at every key position.

  ## Examples

  Plain SQL adapter — required fields only:

      %{
        language: "sql",
        keywords: ["SELECT", "FROM", "WHERE"],
        types: ["INTEGER", "TEXT"],
        functions: [%{name: "COUNT", detail: "count(*)", args: "(*)"}],
        context_boundaries: ["SELECT", "FROM", "WHERE"]
      }

  External SQL adapter with tokenizer options:

      %{
        language: "sql:clickhouse",
        keywords: [...],
        types: [...],
        functions: [...],
        context_boundaries: [...],
        dialect_spec: %{
          identifier_quotes: "`",
          hash_comments: true,
          double_quoted_strings: false,
          case_insensitive_identifiers: true
        }
      }

  JSON DSL adapter with a structural schema:

      %{
        language: "json:elasticsearch",
        keywords: [...],
        types: [],
        functions: [],
        context_boundaries: [],
        context_schema: %{
          root: ["query", "aggs", "sort"],
          children: %{
            "query" => ["match", "term", "bool"],
            "bool" => ["must", "should", "filter"],
            "must" => :array_of_query,
            "match" => :fields
          },
          value_literals: %{"order" => ["asc", "desc"]}
        }
      }

  Size caps on `:keywords`, `:types`, `:functions`, `:context_schema.root`,
  and `:context_schema.children` are enforced at the dispatch layer —
  see `Lotus.Source.Adapter.editor_config/1` for exact limits.
  """
  @callback editor_config(state :: term()) :: %{
              required(:language) => String.t(),
              required(:keywords) => [String.t()],
              required(:types) => [String.t()],
              required(:functions) => [%{name: String.t(), detail: String.t(), args: String.t()}],
              required(:context_boundaries) => [String.t()],
              optional(:dialect_spec) => dialect_spec(),
              optional(:context_schema) => context_schema()
            }

  @optional_callbacks [
    sanitize_query: 3,
    transform_bound_query: 3,
    extract_accessed_resources: 2,
    apply_pagination: 3,
    needs_preflight?: 2,
    substitute_variable: 5,
    substitute_list_variable: 5,
    validate_statement: 3,
    parse_qualified_name: 2,
    validate_identifier: 3,
    supported_filter_operators: 1,
    ai_context: 1,
    prepare_for_analysis: 2,
    query_language: 1,
    hierarchy_label: 1,
    example_query: 3,
    can_handle?: 1,
    wrap: 2,
    transform_statement: 2
  ]

  # Conservative fallback deny rules applied when no adapter can be resolved
  # for a source name (e.g., typo'd repo, unconfigured source). Owned here so
  # generic cross-cutting modules like `Lotus.Visibility` don't need to reach
  # into the Ecto subtree for a sensible default. Built-in Ecto dialects
  # (Postgres, MySQL, SQLite) override these via their own callbacks.
  @fallback_table_denies [
    {"pg_catalog", ~r/.*/},
    {"information_schema", ~r/.*/},
    {nil, ~r/^sqlite_/},
    {nil, "schema_migrations"},
    {"public", "schema_migrations"},
    {"public", "lotus_queries"},
    {nil, "lotus_queries"},
    {"public", "lotus_query_visualizations"},
    {nil, "lotus_query_visualizations"},
    {"public", "lotus_dashboards"},
    {nil, "lotus_dashboards"},
    {"public", "lotus_dashboard_cards"},
    {nil, "lotus_dashboard_cards"},
    {"public", "lotus_dashboard_filters"},
    {nil, "lotus_dashboard_filters"},
    {"public", "lotus_dashboard_card_filter_mappings"},
    {nil, "lotus_dashboard_card_filter_mappings"}
  ]

  @fallback_schema_denies [
    "pg_catalog",
    "information_schema",
    "mysql",
    "performance_schema",
    "sys"
  ]

  @doc """
  Built-in table-level deny rules to apply when no adapter can be resolved.

  Returns a conservative shotgun-union list covering Postgres, MySQL, and
  SQLite system-schema patterns plus Lotus's own storage tables. Callers with
  an `%Adapter{}` struct should prefer `builtin_denies/1` (the struct dispatch
  helper), which routes to the adapter's own rules.
  """
  @spec builtin_denies() :: [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]
  def builtin_denies, do: @fallback_table_denies

  @doc """
  Built-in schema-level deny patterns to apply when no adapter can be resolved.

  Callers with an `%Adapter{}` struct should prefer `builtin_schema_denies/1`.
  """
  @spec builtin_schema_denies() :: [String.t() | Regex.t()]
  def builtin_schema_denies, do: @fallback_schema_denies

  # ---------------------------------------------------------------------------
  # Dispatch helpers — stateful (pass adapter.state as first arg)
  # ---------------------------------------------------------------------------

  @doc "Execute a SQL query via the adapter."
  @spec execute_query(t(), String.t(), list(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_query(%__MODULE__{module: mod, state: state}, sql, params, opts) do
    mod.execute_query(state, sql, params, opts)
  end

  @doc "Execute a function within a transaction via the adapter."
  @spec transaction(t(), (term() -> any()), keyword()) :: {:ok, any()} | {:error, any()}
  def transaction(%__MODULE__{module: mod, state: state}, fun, opts) do
    mod.transaction(state, fun, opts)
  end

  @doc "List all schemas via the adapter."
  @spec list_schemas(t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_schemas(%__MODULE__{module: mod, state: state}) do
    mod.list_schemas(state)
  end

  @doc "List tables via the adapter."
  @spec list_tables(t(), [String.t()], keyword()) ::
          {:ok, [{String.t() | nil, String.t()}]} | {:error, term()}
  def list_tables(%__MODULE__{module: mod, state: state}, schemas, opts) do
    mod.list_tables(state, schemas, opts)
  end

  @doc "Get column definitions for a table via the adapter."
  @spec describe_table(t(), String.t() | nil, String.t()) ::
          {:ok, [column_def()]} | {:error, term()}
  def describe_table(%__MODULE__{module: mod, state: state}, schema, table) do
    mod.describe_table(state, schema, table)
  end

  @doc "Resolve which schema contains a table via the adapter."
  @spec resolve_table_namespace(t(), String.t(), [String.t()]) ::
          {:ok, String.t() | nil} | {:error, term()}
  def resolve_table_namespace(%__MODULE__{module: mod, state: state}, table, schemas) do
    mod.resolve_table_namespace(state, table, schemas)
  end

  @doc "Get the execution plan for a query via the adapter."
  @spec query_plan(t(), String.t(), list(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def query_plan(%__MODULE__{module: mod, state: state}, sql, params, opts) do
    mod.query_plan(state, sql, params, opts)
  end

  @doc "Return built-in deny rules via the adapter."
  @spec builtin_denies(t()) :: [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]
  def builtin_denies(%__MODULE__{module: mod, state: state}) do
    mod.builtin_denies(state)
  end

  @doc "Return built-in schema denies via the adapter."
  @spec builtin_schema_denies(t()) :: [String.t() | Regex.t()]
  def builtin_schema_denies(%__MODULE__{module: mod, state: state}) do
    mod.builtin_schema_denies(state)
  end

  @doc "Return default schemas via the adapter."
  @spec default_schemas(t()) :: [String.t()]
  def default_schemas(%__MODULE__{module: mod, state: state}) do
    mod.default_schemas(state)
  end

  @doc "Check data source health via the adapter."
  @spec health_check(t()) :: :ok | {:error, term()}
  def health_check(%__MODULE__{module: mod, state: state}) do
    mod.health_check(state)
  end

  @doc "Disconnect from the data source via the adapter."
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{module: mod, state: state}) do
    mod.disconnect(state)
  end

  # ---------------------------------------------------------------------------
  # Dispatch helpers — Pipeline (optional callbacks with defaults)
  # ---------------------------------------------------------------------------

  @doc "Validate statement safety via the adapter. Returns `:ok` if not implemented."
  @spec sanitize_query(t(), Statement.t(), keyword()) :: :ok | {:error, String.t()}
  def sanitize_query(%__MODULE__{module: mod, state: state}, %Statement{} = statement, opts) do
    if function_exported?(mod, :sanitize_query, 3),
      do: mod.sanitize_query(state, statement, opts),
      else: :ok
  end

  @doc """
  Rewrite the statement after variable substitution, before filters and sorts
  are applied. Returns the statement unchanged if the adapter doesn't
  implement `transform_bound_query/3`.
  """
  @spec transform_bound_query(t(), Statement.t(), keyword()) :: Statement.t()
  def transform_bound_query(
        %__MODULE__{module: mod, state: state},
        %Statement{} = statement,
        opts
      ) do
    if function_exported?(mod, :transform_bound_query, 3),
      do: mod.transform_bound_query(state, statement, opts),
      else: statement
  end

  @doc """
  Extract accessed resources for preflight checks. Returns
  `{:unrestricted, reason}` if the adapter doesn't implement the callback —
  callers must consult the host-app `:allow_unrestricted_resources` opt-in
  before allowing the statement through.
  """
  @spec extract_accessed_resources(t(), Statement.t()) ::
          {:ok, MapSet.t({String.t() | nil, String.t()})}
          | {:error, term()}
          | {:unrestricted, String.t()}
  def extract_accessed_resources(%__MODULE__{module: mod, state: state}, %Statement{} = statement) do
    if function_exported?(mod, :extract_accessed_resources, 2),
      do: mod.extract_accessed_resources(state, statement),
      else:
        {:unrestricted, "adapter #{inspect(mod)} does not implement extract_accessed_resources/2"}
  end

  @doc """
  Apply pagination to the statement. The paginated statement carries any
  count spec in `statement.meta[:count_spec]`. Returns the statement
  unchanged if the adapter doesn't implement `apply_pagination/3`.
  """
  @spec apply_pagination(t(), Statement.t(), keyword()) :: Statement.t()
  def apply_pagination(%__MODULE__{module: mod, state: state}, %Statement{} = statement, opts) do
    if function_exported?(mod, :apply_pagination, 3),
      do: mod.apply_pagination(state, statement, opts),
      else: statement
  end

  @doc """
  Whether the statement needs the visibility preflight check. Returns `true`
  if the adapter doesn't implement `needs_preflight?/2` — the safer default.
  """
  @spec needs_preflight?(t(), Statement.t()) :: boolean()
  def needs_preflight?(%__MODULE__{module: mod, state: state}, %Statement{} = statement) do
    if function_exported?(mod, :needs_preflight?, 2),
      do: mod.needs_preflight?(state, statement),
      else: true
  end

  # ---------------------------------------------------------------------------
  # Dispatch helpers — SQL generation (pass adapter.state for correct dispatch)
  # ---------------------------------------------------------------------------

  @doc "Quote a SQL identifier via the adapter."
  @spec quote_identifier(t(), String.t()) :: String.t()
  def quote_identifier(%__MODULE__{module: mod, state: state}, identifier) do
    mod.quote_identifier(state, identifier)
  end

  @doc """
  Substitute a `{{var}}` scalar variable via the adapter. Returns
  `{:error, :unsupported}` when the adapter does not implement the callback.
  """
  @spec substitute_variable(t(), Statement.t(), String.t(), term(), atom() | nil) ::
          {:ok, Statement.t()} | {:error, term()}
  def substitute_variable(
        %__MODULE__{module: mod, state: state},
        %Statement{} = statement,
        var_name,
        value,
        type
      ) do
    if function_exported?(mod, :substitute_variable, 5),
      do: mod.substitute_variable(state, statement, var_name, value, type),
      else: {:error, :unsupported}
  end

  @doc """
  Substitute a `{{var}}` list variable via the adapter. Returns
  `{:error, :unsupported}` when the adapter does not implement the callback.
  """
  @spec substitute_list_variable(t(), Statement.t(), String.t(), [term()], atom() | nil) ::
          {:ok, Statement.t()} | {:error, term()}
  def substitute_list_variable(
        %__MODULE__{module: mod, state: state},
        %Statement{} = statement,
        var_name,
        values,
        type
      )
      when is_list(values) do
    if function_exported?(mod, :substitute_list_variable, 5),
      do: mod.substitute_list_variable(state, statement, var_name, values, type),
      else: {:error, :unsupported}
  end

  @doc """
  Validate a statement via the adapter. Returns `:ok` if the adapter does
  not implement the callback (trust-on-execute).
  """
  @spec validate_statement(t(), Statement.t(), keyword()) :: :ok | {:error, term()}
  def validate_statement(
        %__MODULE__{module: mod, state: state},
        %Statement{} = statement,
        opts
      ) do
    if function_exported?(mod, :validate_statement, 3),
      do: mod.validate_statement(state, statement, opts),
      else: :ok
  end

  @doc """
  Parse a qualified name into hierarchy components via the adapter.
  Returns `{:ok, [name]}` (single-component) if the adapter does not
  implement the callback.
  """
  @spec parse_qualified_name(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def parse_qualified_name(%__MODULE__{module: mod, state: state}, name) when is_binary(name) do
    if function_exported?(mod, :parse_qualified_name, 2),
      do: mod.parse_qualified_name(state, name),
      else: {:ok, [name]}
  end

  @doc """
  Validate an identifier for the given kind via the adapter. Returns `:ok`
  (permissive) if the adapter does not implement the callback.
  """
  @spec validate_identifier(t(), :schema | :table | :column, String.t()) ::
          :ok | {:error, String.t()}
  def validate_identifier(%__MODULE__{module: mod, state: state}, kind, value)
      when kind in [:schema, :table, :column] and is_binary(value) do
    if function_exported?(mod, :validate_identifier, 3),
      do: mod.validate_identifier(state, kind, value),
      else: :ok
  end

  @doc """
  Return the filter operators this adapter's `apply_filters/3` supports.
  Defaults to all of `Lotus.Query.Filter.operators/0` if the adapter does
  not declare a subset.
  """
  @spec supported_filter_operators(t()) :: [atom()]
  def supported_filter_operators(%__MODULE__{module: mod, state: state}) do
    if function_exported?(mod, :supported_filter_operators, 1),
      do: mod.supported_filter_operators(state),
      else: Filter.operators()
  end

  @doc "Apply filters to a statement via the adapter. Empty filters short-circuit."
  @spec apply_filters(t(), Statement.t(), list()) :: Statement.t()
  def apply_filters(_adapter, %Statement{} = statement, []), do: statement

  def apply_filters(%__MODULE__{module: mod, state: state}, %Statement{} = statement, filters) do
    mod.apply_filters(state, statement, filters)
  end

  @doc "Apply sorts to a statement via the adapter. Empty sorts short-circuit."
  @spec apply_sorts(t(), Statement.t(), list()) :: Statement.t()
  def apply_sorts(_adapter, %Statement{} = statement, []), do: statement

  def apply_sorts(%__MODULE__{module: mod, state: state}, %Statement{} = statement, sorts) do
    mod.apply_sorts(state, statement, sorts)
  end

  @doc "Format an error via the adapter."
  @spec format_error(t(), any()) :: String.t()
  def format_error(%__MODULE__{module: mod, state: state}, error) do
    mod.format_error(state, error)
  end

  @doc "Return handled error modules via the adapter."
  @spec handled_errors(t()) :: [module()]
  def handled_errors(%__MODULE__{module: mod, state: state}) do
    mod.handled_errors(state)
  end

  @doc "Return the source type via the adapter."
  @spec source_type(t()) :: source_type()
  def source_type(%__MODULE__{module: mod, state: state}) do
    mod.source_type(state)
  end

  @doc "Check feature support via the adapter."
  @spec supports_feature?(t(), atom()) :: boolean()
  def supports_feature?(%__MODULE__{module: mod, state: state}, feature) do
    mod.supports_feature?(state, feature)
  end

  @doc "Return the query language identifier via the adapter."
  @spec query_language(t()) :: String.t()
  def query_language(%__MODULE__{module: mod, state: state}) do
    if function_exported?(mod, :query_language, 1),
      do: mod.query_language(state),
      else: "sql"
  end

  # Hard limits on the free-form AI context fields. Adapters that return
  # values over these bounds are truncated at this dispatch layer with a
  # one-time warning — prevents a noisy or compromised adapter from
  # bloating the prompt beyond the LLM's context budget.
  @ai_context_max_example_query_bytes 2048
  @ai_context_max_syntax_notes_bytes 1024
  @ai_context_max_error_patterns 20

  # Constrains the `:language` field to a small character set so untrusted
  # adapters can't inject prompt text through it.
  @ai_context_language_regex ~r/\A[a-z0-9]+:[a-z0-9_-]+\z/

  @doc """
  Return the adapter's AI context, with free-form fields capped at safe
  sizes.

  Returns `{:error, :ai_not_supported}` if the adapter does not implement
  `ai_context/1` — the host can branch on this to disable AI features for
  the source.

  Oversized `:example_query`, `:syntax_notes`, or `:error_patterns` are
  truncated at the dispatch layer with a one-time `Logger.warning/1` per
  adapter module. A `:language` value that doesn't match the allowed
  character set (`^[a-z0-9]+:[a-z0-9_-]+$`) is replaced with `"unknown"`.
  """
  @spec ai_context(t()) :: {:ok, ai_context_map()} | {:error, term()}
  def ai_context(%__MODULE__{module: mod, state: state}) do
    if function_exported?(mod, :ai_context, 1) do
      case mod.ai_context(state) do
        {:ok, ctx} when is_map(ctx) -> {:ok, sanitize_ai_context(mod, ctx)}
        {:error, _} = err -> err
        other -> {:error, {:invalid_ai_context, other}}
      end
    else
      {:error, :ai_not_supported}
    end
  end

  @doc """
  Prepare a statement for optimization analysis via the adapter. Returns
  `{:error, :unsupported}` if the adapter does not implement
  `prepare_for_analysis/2` — callers skip optimization for that adapter.
  """
  @spec prepare_for_analysis(t(), Statement.t()) :: {:ok, Statement.t()} | {:error, term()}
  def prepare_for_analysis(%__MODULE__{module: mod, state: state}, %Statement{} = statement) do
    if function_exported?(mod, :prepare_for_analysis, 2),
      do: mod.prepare_for_analysis(state, statement),
      else: {:error, :unsupported}
  end

  # Trust boundary: untrusted adapters supply only `:language` to the
  # prompt. Free-form fields (`:example_query`, `:syntax_notes`,
  # `:error_patterns`) are discarded so a compromised or incidentally
  # adversarial adapter can't inject prompt text. Capability
  # declarations still apply — they gate feature visibility, not prompt
  # content — but their reason strings are replaced with a generic
  # fallback for untrusted adapters (same injection concern).
  defp sanitize_ai_context(mod, ctx) do
    ctx
    |> sanitize_language(mod)
    |> apply_trust_boundary(mod)
    |> truncate_bytes(
      :example_query,
      @ai_context_max_example_query_bytes,
      mod
    )
    |> truncate_bytes(
      :syntax_notes,
      @ai_context_max_syntax_notes_bytes,
      mod
    )
    |> truncate_list(:error_patterns, @ai_context_max_error_patterns, mod)
    |> normalize_capabilities(mod)
  end

  defp apply_trust_boundary(ctx, mod) do
    if Lotus.Config.trusted_source_adapter?(mod) do
      ctx
    else
      ctx
      |> Map.put(:example_query, "")
      |> Map.put(:syntax_notes, "")
      |> Map.put(:error_patterns, [])
    end
  end

  # Default to all-supported when the adapter omits `:capabilities` —
  # existing adapters that returned `{:ok, ctx}` before this extension
  # should opt into everything. For untrusted adapters, any `{false,
  # reason}` has its reason replaced with a generic fallback.
  @generic_unsupported_reason "This feature is not available for this data source."

  defp normalize_capabilities(ctx, mod) do
    caps =
      ctx
      |> Map.get(:capabilities, %{})
      |> ensure_capability(:generation)
      |> ensure_capability(:optimization)
      |> ensure_capability(:explanation)
      |> filter_capability_reasons(mod)

    Map.put(ctx, :capabilities, caps)
  end

  defp ensure_capability(caps, key) do
    case Map.get(caps, key) do
      true -> caps
      {false, reason} when is_binary(reason) -> caps
      false -> Map.put(caps, key, {false, @generic_unsupported_reason})
      nil -> Map.put(caps, key, true)
      _ -> Map.put(caps, key, true)
    end
  end

  defp filter_capability_reasons(caps, mod) do
    if Lotus.Config.trusted_source_adapter?(mod) do
      caps
    else
      Enum.into(caps, %{}, fn
        {key, {false, _reason}} -> {key, {false, @generic_unsupported_reason}}
        {key, true} -> {key, true}
      end)
    end
  end

  defp sanitize_language(ctx, mod) do
    case Map.get(ctx, :language) do
      lang when is_binary(lang) ->
        if Regex.match?(@ai_context_language_regex, lang) do
          ctx
        else
          warn_ai_context_once(mod, :language, "invalid format")
          Map.put(ctx, :language, "unknown")
        end

      _ ->
        warn_ai_context_once(mod, :language, "missing or non-binary")
        Map.put(ctx, :language, "unknown")
    end
  end

  defp truncate_bytes(ctx, key, limit, mod) do
    case Map.get(ctx, key) do
      value when is_binary(value) and byte_size(value) > limit ->
        warn_ai_context_once(mod, key, "exceeds #{limit} bytes, truncating")
        Map.put(ctx, key, binary_part(value, 0, limit))

      _ ->
        ctx
    end
  end

  defp truncate_list(ctx, key, limit, mod) do
    case Map.get(ctx, key) do
      list when is_list(list) and length(list) > limit ->
        warn_ai_context_once(mod, key, "exceeds #{limit} entries, truncating")
        Map.put(ctx, key, Enum.take(list, limit))

      _ ->
        ctx
    end
  end

  # Log each (adapter, field) truncation/repair once per BEAM node so a
  # misconfigured adapter doesn't spam the log on every AI call.
  defp warn_ai_context_once(mod, field, msg) do
    key = {__MODULE__, :ai_context_warn, mod, field}

    case :persistent_term.get(key, :none) do
      :warned ->
        :ok

      :none ->
        :persistent_term.put(key, :warned)
        require Logger
        Logger.warning("ai_context from #{inspect(mod)} field #{inspect(field)}: #{msg}")
    end
  end

  # Caps on editor_config list sizes. A noisy or compromised adapter
  # could otherwise ship a huge payload that flows over LiveView to
  # every editor session. Enforced at the dispatch layer, same
  # philosophy as the ai_context caps above.
  @editor_config_max_keywords 2000
  @editor_config_max_types 2000
  @editor_config_max_functions 500
  @editor_config_max_context_schema_root 200
  @editor_config_max_context_schema_children 500

  @editor_config_known_keys [
    :language,
    :keywords,
    :types,
    :functions,
    :context_boundaries,
    :dialect_spec,
    :context_schema
  ]

  @doc """
  Return editor configuration via the adapter, with list sizes capped
  at safe limits.

  Unknown top-level keys are dropped; oversized `:keywords`, `:types`,
  `:functions`, `:context_schema.root`, and `:context_schema.children`
  are truncated with a one-time `Logger.warning/1` per adapter module.
  Prevents a misbehaving adapter from bloating every editor session's
  LiveView payload.
  """
  @spec editor_config(t()) :: map()
  def editor_config(%__MODULE__{module: mod, state: state}) do
    state |> mod.editor_config() |> sanitize_editor_config(mod)
  end

  defp sanitize_editor_config(config, mod) when is_map(config) do
    config
    |> Map.take(@editor_config_known_keys)
    |> truncate_list_field(:keywords, @editor_config_max_keywords, mod)
    |> truncate_list_field(:types, @editor_config_max_types, mod)
    |> truncate_list_field(:functions, @editor_config_max_functions, mod)
    |> truncate_context_schema(mod)
  end

  defp sanitize_editor_config(other, _mod), do: other

  defp truncate_list_field(config, key, limit, mod) do
    case Map.get(config, key) do
      list when is_list(list) and length(list) > limit ->
        warn_editor_config_once(mod, key, "exceeds #{limit} entries, truncating")
        Map.put(config, key, Enum.take(list, limit))

      _ ->
        config
    end
  end

  defp truncate_context_schema(config, mod) do
    case Map.get(config, :context_schema) do
      %{} = schema ->
        schema =
          schema
          |> truncate_schema_root(mod)
          |> truncate_schema_children(mod)

        Map.put(config, :context_schema, schema)

      _ ->
        config
    end
  end

  defp truncate_schema_root(schema, mod) do
    case Map.get(schema, :root) do
      list when is_list(list) and length(list) > @editor_config_max_context_schema_root ->
        warn_editor_config_once(
          mod,
          :context_schema_root,
          "exceeds #{@editor_config_max_context_schema_root} entries, truncating"
        )

        Map.put(schema, :root, Enum.take(list, @editor_config_max_context_schema_root))

      _ ->
        schema
    end
  end

  defp truncate_schema_children(schema, mod) do
    case Map.get(schema, :children) do
      %{} = children when map_size(children) > @editor_config_max_context_schema_children ->
        warn_editor_config_once(
          mod,
          :context_schema_children,
          "exceeds #{@editor_config_max_context_schema_children} entries, truncating"
        )

        truncated =
          children
          |> Enum.take(@editor_config_max_context_schema_children)
          |> Map.new()

        Map.put(schema, :children, truncated)

      _ ->
        schema
    end
  end

  defp warn_editor_config_once(mod, field, msg) do
    key = {__MODULE__, :editor_config_warn, mod, field}

    case :persistent_term.get(key, :none) do
      :warned ->
        :ok

      :none ->
        :persistent_term.put(key, :warned)
        require Logger
        Logger.warning("editor_config from #{inspect(mod)} field #{inspect(field)}: #{msg}")
    end
  end

  @doc "Wrap a statement with a limit clause via the adapter."
  @spec limit_query(t(), String.t(), pos_integer()) :: String.t()
  def limit_query(%__MODULE__{module: mod, state: state}, statement, limit) do
    mod.limit_query(state, statement, limit)
  end

  @doc "Return the hierarchy label via the adapter."
  @spec hierarchy_label(t()) :: String.t()
  def hierarchy_label(%__MODULE__{module: mod, state: state}) do
    if function_exported?(mod, :hierarchy_label, 1),
      do: mod.hierarchy_label(state),
      else: "Tables"
  end

  @doc "Return an example query via the adapter."
  @spec example_query(t(), String.t(), String.t() | nil) :: String.t()
  def example_query(%__MODULE__{module: mod, state: state}, table, schema) do
    if function_exported?(mod, :example_query, 3),
      do: mod.example_query(state, table, schema),
      else: "SELECT value_column FROM #{table}"
  end

  @doc """
  Rewrite the statement before variable binding. Returns the statement
  unchanged if the adapter doesn't implement `transform_statement/2`.
  """
  @spec transform_statement(t(), Statement.t()) :: Statement.t()
  def transform_statement(%__MODULE__{module: mod, state: state}, %Statement{} = statement) do
    if function_exported?(mod, :transform_statement, 2),
      do: mod.transform_statement(state, statement),
      else: statement
  end

  @doc "Map a database type to a Lotus type via the adapter."
  @spec db_type_to_lotus_type(t(), String.t()) :: atom()
  def db_type_to_lotus_type(%__MODULE__{module: mod, state: state}, db_type) do
    mod.db_type_to_lotus_type(state, db_type)
  end
end
