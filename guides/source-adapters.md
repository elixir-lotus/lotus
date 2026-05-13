# Source Adapters

## Overview

Source adapters wrap data sources behind a uniform callback interface so the
Lotus execution pipeline does not depend on any particular database driver or
connection strategy. Every data source — whether it is an Ecto repo, a raw
database connection, or an external REST / DSL engine — is represented as a
`%Lotus.Source.Adapter{}` struct that the runner, preflight, cache, and
introspection modules all accept identically.

`Lotus.Source` provides convenience functions (`resolve!/2`, `source_type/1`,
`supports_feature?/2`, `hierarchy_label/1`, `query_language/1`,
`supported_filter_operators/1`, `prepare_for_analysis/2`) that accept adapter
structs, source-name strings, or repo modules and resolve lazily as needed.

For SQL databases backed by Ecto, per-dialect adapter modules
(`Lotus.Source.Adapters.Postgres`, `Lotus.Source.Adapters.MySQL`,
`Lotus.Source.Adapters.SQLite3`) handle dialect-specific behaviour. External
adapters for other databases or non-SQL data sources are registered via the
`:source_adapters` config.

## How It Works

The adapter struct carries four fields:

| Field | Type | Description |
|---|---|---|
| `name` | `String.t()` | Human-readable identifier (e.g. `"main"`, `"warehouse"`) |
| `module` | `module()` | The module implementing `Lotus.Source.Adapter` callbacks |
| `state` | `term()` | Opaque connection state managed by the adapter (e.g. an Ecto.Repo module) |
| `source_type` | `atom()` | Database kind — `:postgres`, `:mysql`, `:sqlite`, `:other`, or any atom an external adapter declares |

When a query is executed, Lotus asks the configured **source resolver** to turn
a repo name (or module) into an `%Adapter{}` struct. The resolver iterates
through registered adapters (external first, then built-in per-dialect, then
the generic Ecto fallback), calling `can_handle?/1` on each until one claims
the entry. That adapter's `wrap/2` builds the struct, and from that point
every pipeline stage dispatches through `Adapter` helpers.

```
User calls Lotus.run_statement("SELECT 1", [], repo: "main")
  |
  v
Source Resolver  -->  per-dialect adapter (Adapters.Postgres)
                      -->  %Adapter{name: "main",
                                    module: Adapters.Postgres,
                                    state: MyApp.Repo,
                                    source_type: :postgres}
  |
  v
Runner / Preflight / Schema  -->  Adapter.execute_query(adapter, sql, params, opts)
                                     \-->  Adapters.Postgres.execute_query(MyApp.Repo, ...)
```

## The Statement Contract

All pipeline callbacks operate on a `%Lotus.Query.Statement{}`:

```elixir
%Lotus.Query.Statement{
  adapter: MyApp.Adapters.Echo,   # module that owns this text
  text:    "SELECT * FROM t",     # adapter-native payload (term())
  params:  [],                    # bound parameter values
  meta:    %{}                    # adapter-specific metadata
}
```

The `:text` field is deliberately typed `term()` — SQL text for Ecto-backed
adapters, a JSON body for Elasticsearch, a DSL AST for other engines. The
pipeline is a series of pure `statement -> statement` transforms; adapters
return new structs rather than mutating in place.

Relevant keys inside `:meta`:

- `:count_spec` — placed by `apply_pagination/3` when the caller requested
  `count: :exact` and the adapter uses Strategy B (separate count query).
  Shape: `%{query: adapter-native, params: list()}`. Lotus core runs it
  through the same adapter. See "Exact counts" below.

## Exact counts — two adapter strategies

When the caller requests `count: :exact`, the adapter picks one of two
strategies to surface the pre-pagination total:

**Strategy A — inline count** (new for engines where count comes back with
the data). `execute_query/4` includes `:total_count` directly in its result
map:

```elixir
{:ok, %{columns: [...], rows: [...], num_rows: 3, total_count: 1_247}}
```

Use this for engines that return the total as a side-effect of the main
query — Elasticsearch's `hits.total.value` with `track_total_hits: true`,
MongoDB's `$facet`, any store whose search response includes the match count
for free. `apply_pagination/3` should NOT set `:count_spec` — its only job
is to arrange for the main query to return the count (e.g. add
`"track_total_hits": true` to the ES body).

**Strategy B — separate count query** (classic SQL path). `apply_pagination/3`
places a `count_spec` in `statement.meta`; Lotus core runs it through the
same adapter after the main query. Standard for SQL adapters — a
`SELECT count(*) FROM ...` around the filtered query.

**Precedence rule.** Adapters pick one strategy per dataset — not both. If
both are present anyway, Strategy A wins: the inline count is authoritative
and the count_spec is not run.

Adapters that cannot provide an exact count at all simply don't populate
either channel — `Result.meta[:total_count]` ends up `nil` and
`:total_mode` is `:exact` (honest signal that the caller asked but no
number was produced).

## Default Behaviour

If you are using Ecto repos and static configuration, no changes are needed.
The default source resolver (`Lotus.Source.Resolvers.Static`) reads your
existing `:data_sources` config and wraps each repo in the appropriate
per-dialect adapter automatically:

- PostgreSQL repos (`Ecto.Adapters.Postgres`) → `Lotus.Source.Adapters.Postgres`
- MySQL repos (`Ecto.Adapters.MyXQL`) → `Lotus.Source.Adapters.MySQL`
- SQLite repos (`Ecto.Adapters.SQLite3`) → `Lotus.Source.Adapters.SQLite3`
- Unknown Ecto repos fall back to `Lotus.Source.Adapters.Ecto` with the `Default`
  dialect

Standard Ecto configuration:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,
  default_source: "main",
  data_sources: %{
    "main"      => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  }
```

The public API (`Lotus.run_query/2`, `Lotus.run_statement/3`, etc.) is
unchanged.

## Configuration Keys

```elixir
config :lotus,
  # Turns repo names into %Adapter{} structs.
  source_resolver:        MyApp.SourceResolver,

  # External adapter modules consulted before built-in adapters.
  # Each must implement can_handle?/1 and wrap/2.
  source_adapters:        [MyApp.MSSQLAdapter, MyApp.EchoAdapter],

  # Adapters whose ai_context/1 output is plumbed through to the LLM
  # prompt unchanged. Built-in Ecto adapters are always trusted.
  trusted_source_adapters: [MyApp.MSSQLAdapter],

  # Loads schema/table/column visibility rules.
  visibility_resolver:     MyApp.VisibilityResolver,

  # Global allow-bypass for adapters that return {:unrestricted, _}
  # from extract_accessed_resources/2.
  allow_unrestricted_resources: false
```

All keys are optional. When omitted, the defaults read from static application
config.

## Building a Custom Adapter

Two paths, depending on whether your data source uses Ecto.

### A. Ecto-backed adapter (new SQL dialect)

Use this when Ecto already ships a driver for the database (e.g. `Tds` for
MSSQL) but Lotus does not ship a built-in dialect for it.

1. Write a **Dialect module** implementing `Lotus.Source.Adapters.Ecto.Dialect`.
   The dialect encapsulates all SQL-specific behaviour (dialect-specific
   placeholder syntax, identifier quoting, EXPLAIN variant, introspection
   queries, built-in deny rules).
2. Write an **adapter module** that pulls in the shared Ecto machinery via
   `use Lotus.Source.Adapters.Ecto, dialect: ...`. The macro injects default
   implementations for every `Lotus.Source.Adapter` callback, delegating to
   the dialect where appropriate. All callbacks are `defoverridable`.
3. **Register** via `:source_adapters`.

```elixir
defmodule MyApp.Dialects.MSSQL do
  @behaviour Lotus.Source.Adapters.Ecto.Dialect

  # -- Identity ---------------------------------------------------------------
  @impl true
  def source_type, do: :mssql

  @impl true
  def ecto_adapter, do: Ecto.Adapters.Tds

  @impl true
  def query_language, do: "sql:tsql"

  @impl true
  def limit_query(statement, limit),
    do: "SELECT TOP #{limit} * FROM (#{statement}) AS t"

  # -- Transaction & session --------------------------------------------------
  # execute_in_transaction/3, set_statement_timeout/2, set_search_path/2

  # -- Error handling ---------------------------------------------------------
  # format_error/1, handled_errors/0

  # -- SQL generation ---------------------------------------------------------
  # quote_identifier/1, param_placeholder/3, limit_offset_placeholders/2,
  # apply_filters/2, apply_sorts/2, query_plan/4

  # -- Visibility & deny rules -----------------------------------------------
  # builtin_denies/1, builtin_schema_denies/1, default_schemas/1

  # -- Introspection ----------------------------------------------------------
  # list_schemas/1, list_tables/3, describe_table/3, resolve_table_namespace/3
end

defmodule MyApp.Adapters.MSSQL do
  use Lotus.Source.Adapters.Ecto, dialect: MyApp.Dialects.MSSQL
end
```

#### Dialect callbacks

Callbacks are organized by category. All required callbacks must be
implemented; optional callbacks have sensible defaults.

**Required:**

| Callback | Category |
|---|---|
| `source_type/0` | Identity |
| `ecto_adapter/0` | Identity |
| `query_language/0` | Identity |
| `limit_query/2` | Identity |
| `execute_in_transaction/3` | Transaction & session |
| `set_statement_timeout/2` | Transaction & session |
| `set_search_path/2` | Transaction & session |
| `format_error/1` | Error handling |
| `handled_errors/0` | Error handling |
| `quote_identifier/1` | SQL generation |
| `param_placeholder/3` | SQL generation |
| `limit_offset_placeholders/2` | SQL generation |
| `apply_filters/2` | SQL generation |
| `apply_sorts/2` | SQL generation |
| `query_plan/4` | SQL generation |
| `builtin_denies/1` | Visibility & deny rules |
| `builtin_schema_denies/1` | Visibility & deny rules |
| `default_schemas/1` | Visibility & deny rules |
| `list_schemas/1` | Introspection |
| `list_tables/3` | Introspection |
| `describe_table/3` | Introspection |
| `resolve_table_namespace/3` | Introspection |

**Optional** (defaults provided by `Lotus.Source.Adapters.Ecto`):

| Callback | Category | Default |
|---|---|---|
| `supports_feature?/1` | Identity | Returns `false` |
| `hierarchy_label/0` | Identity | `"Tables"` |
| `example_query/2` | Identity | Generic `SELECT value_column FROM table` |
| `editor_config/0` | Editor | Empty config (`%{language: "sql", keywords: [], ...}`) |
| `extract_accessed_resources/2` | Visibility | Dialect-specific SQL analysis via `EXPLAIN` + fallback |
| `transform_statement/1` | Statement rewriting | Statement unchanged |
| `needs_preflight?/1` | Visibility | Dialect-specific (skips `EXPLAIN`, `SHOW`, `PRAGMA`) |
| `db_type_to_lotus_type/1` | Type mapping | Maps common SQL types to Lotus types |

### B. Non-Ecto adapter (REST, document store, DSL)

Use this for data sources that do not use Ecto at all — Elasticsearch, Mongo,
ClickHouse's native DSL, a REST API.

Implement `Lotus.Source.Adapter` directly. Lotus ships a first-party reference
implementation in its own test suite at
[`test/support/in_memory_adapter.ex`](../test/support/in_memory_adapter.ex) —
an in-memory DSL-map adapter that exercises the full contract. A copy of it
makes a useful starting point for a new adapter.

Below is an abbreviated stub showing the shape of every required callback —
see the in-memory adapter for full implementations and the DSL-to-rows
executor.

```elixir
defmodule MyApp.Adapters.Echo do
  @behaviour Lotus.Source.Adapter

  alias Lotus.Query.Statement

  # -- Registration -----------------------------------------------------------
  @impl true
  def can_handle?(%{adapter: :echo}), do: true
  def can_handle?(_), do: false

  @impl true
  def wrap(name, %{adapter: :echo} = config) do
    %Lotus.Source.Adapter{
      name: name,
      module: __MODULE__,
      state: config,
      source_type: :echo
    }
  end

  # -- Query execution --------------------------------------------------------
  # The :statement argument is whatever query language the source understands
  # (SQL, JSON DSL, Cypher, etc.). Return a result map with :columns, :rows,
  # :num_rows — Lotus wraps it into %Lotus.Result{}.
  @impl true
  def execute_query(_state, statement, params, _opts) do
    {:ok,
     %{
       columns: ["statement", "param_count"],
       rows: [[inspect(statement), length(params)]],
       num_rows: 1
     }}
  end

  @impl true
  def transaction(state, fun, _opts), do: {:ok, fun.(state)}

  # -- Introspection ----------------------------------------------------------
  @impl true
  def list_schemas(_state), do: {:ok, []}

  @impl true
  def list_tables(_state, _schemas, _opts),
    do: {:ok, [{nil, "messages"}]}

  @impl true
  def describe_table(_state, _schema, _table), do: {:ok, []}

  @impl true
  def resolve_table_namespace(_state, _table, _schemas), do: {:ok, nil}

  # -- Pipeline (filters / sorts / pagination on the statement) ---------------
  @impl true
  def quote_identifier(_state, id), do: id

  @impl true
  def apply_filters(_state, statement, _filters), do: statement

  @impl true
  def apply_sorts(_state, statement, _sorts), do: statement

  @impl true
  def query_plan(_state, _sql, _params, _opts), do: {:ok, nil}

  # -- Safety & visibility ----------------------------------------------------
  @impl true
  def builtin_denies(_state), do: []

  @impl true
  def builtin_schema_denies(_state), do: []

  @impl true
  def default_schemas(_state), do: []

  # -- Lifecycle --------------------------------------------------------------
  @impl true
  def health_check(_state), do: :ok

  @impl true
  def disconnect(_state), do: :ok

  # -- Error handling ---------------------------------------------------------
  @impl true
  def format_error(_state, error), do: inspect(error)

  @impl true
  def handled_errors(_state), do: []

  # -- Identity & presentation ------------------------------------------------
  @impl true
  def source_type(_state), do: :echo

  @impl true
  def supports_feature?(_state, _feature), do: false

  @impl true
  def query_language(_state), do: "echo:dsl"

  @impl true
  def limit_query(_state, statement, _limit), do: statement

  @impl true
  def editor_config(_state),
    do: %{language: "echo:dsl", keywords: [], types: [], functions: [], context_boundaries: []}

  @impl true
  def db_type_to_lotus_type(_state, _db_type), do: :text
end
```

Register it and use it like any other source:

```elixir
config :lotus,
  source_adapters: [MyApp.Adapters.Echo],
  data_sources: %{"echo" => %{adapter: :echo}}

{:ok, result} = Lotus.run_statement("hello", [1, 2, 3], repo: "echo")
# result.rows #=> [["\"hello\"", 3]]
```

## Required vs Optional Callbacks

The full `Lotus.Source.Adapter` contract has ~30 callbacks. Most non-SQL
adapters implement every one of them; the optional list is for adapters that
legitimately cannot support a feature.

**Optional with documented defaults** — omit when not applicable:

| Callback | Default | When to implement |
|---|---|---|
| `sanitize_query/3` | `:ok` | When you need to block specific statement shapes (read-only enforcement, destructive-op blocking). |
| `transform_statement/2` | statement unchanged | Dialect-specific rewrites applied **before** variable binding. |
| `transform_bound_query/3` | statement unchanged | Rewrites applied **after** variable binding (when values are visible). |
| `apply_pagination/3` | statement unchanged | Support `window: [limit:, offset:, count:]` in your source's native syntax. |
| `needs_preflight?/2` | `true` | Skip preflight for read-only introspection statements (`EXPLAIN`, `SHOW`, `PRAGMA`, etc.). |
| `substitute_variable/5` | `{:error, :unsupported}` | Support `{{var}}` in stored queries. **Security boundary — see below.** |
| `substitute_list_variable/5` | `{:error, :unsupported}` | Support list variables. |
| `validate_statement/3` | `:ok` (trust-on-execute) | Validate a draft via an engine's `_validate` endpoint without executing. |
| `parse_qualified_name/2` | `{:ok, [name]}` | Adapters with multi-level namespace hierarchies (`schema.table`, `db.collection`). |
| `validate_identifier/3` | `:ok` (permissive) | Enforce your query language's identifier grammar. |
| `supported_filter_operators/1` | all of `Lotus.Query.Filter.operators/0` | Declare the subset of filter operators your `apply_filters/3` actually handles. |
| `extract_accessed_resources/2` | `{:unrestricted, reason}` | Return `{:ok, MapSet}` of accessed `{schema, table}` tuples so visibility rules apply. **See below.** |
| `ai_context/1` | `{:error, :ai_not_supported}` | Opt into Lotus.AI — language identifier, example query, syntax notes, error patterns, capability gates. |
| `prepare_for_analysis/2` | `{:error, :unsupported}` | Produce a runnable statement for `query_plan/4` analysis — strips `[[ ... ]]`, neutralizes `{{var}}`. |
| `hierarchy_label/1` | `"Tables"` | UI label for the top-level hierarchy (e.g. `"Indices"` for Elasticsearch). |
| `example_query/3` | generic `SELECT` | Source-native example for the query editor's placeholder text. |

## The Security Boundaries

Two callbacks are **security boundaries**. Get them wrong and you open
injection or authorization gaps.

### 1. `substitute_variable/5` — adapter owns injection safety

When a stored query contains `{{var_name}}`, Lotus calls your adapter's
`substitute_variable/5` with the already-cast value. The adapter decides how
to embed it:

- **SQL prepared-statement adapters** (`Lotus.Source.Adapters.Ecto`) append a
  placeholder (`$1`, `?`, …) to `statement.text` and push the value into
  `statement.params`. The database driver handles binding and escaping.
- **JSON / DSL adapters** (Elasticsearch, Mongo) have no prepared-statement
  concept. They inline values directly into `statement.text`. **This is the
  primary injection boundary.** Use a language-appropriate escaper
  (`Lotus.JSON.encode!/1` for JSON DSLs, an AST builder for structured
  languages, never raw `to_string/1` + string interpolation).

Return `{:error, :unsupported}` if your adapter has no `{{var}}` mental model
at all — stored queries against that source will then refuse variable
substitution cleanly rather than producing broken queries.

### 2. `extract_accessed_resources/2` — visibility enforcement

`Lotus.Preflight` uses the set of `{schema, table}` tuples returned here to
check each relation against configured visibility rules before executing.
Three return shapes:

- `{:ok, MapSet.new([{schema, table}, ...])}` — exact set; preflight applies
  visibility rules as usual.
- `{:error, reason}` — adapter refuses the statement (e.g. parse error).
  Lotus blocks execution and surfaces the reason.
- `{:unrestricted, reason}` — adapter **cannot** determine which relations the
  statement touches (common for opaque DSLs or engine-side joins). Lotus
  blocks by default; the host app opts in via
  `config :lotus, :allow_unrestricted_resources: true` (global) or
  `allow_unrestricted_resources: true` in a per-source config map. Operators
  who opt in are effectively saying "I trust every query against this source".

Never return `{:unrestricted, _}` from an adapter that *can* extract
relations — doing so disables visibility enforcement silently.

## AI Adapter Support

Opt into `Lotus.AI` by implementing `ai_context/1`:

```elixir
@impl true
def ai_context(_state) do
  {:ok,
   %{
     language: "mysource:dsl",
     example_query: "from users where id = {{user_id}}",
     syntax_notes: "Use '|' for pipelines. String literals are single-quoted.",
     error_patterns: [
       %{pattern: ~r/Table .* not found/,
         hint: "Check the table name via list_tables."}
     ],
     capabilities: %{
       generation:   true,
       optimization: {false, "This source has no execution plan."},
       explanation:  true
     }
   }}
end
```

**Fixed keys with hard byte limits** — returns are truncated at the dispatch
layer with a one-time warning per `(adapter, field)` pair:

| Key | Purpose | Limit |
|---|---|---|
| `:language` | Query-language identifier. Must match `^[a-z0-9]+:[a-z0-9_-]+$`. | — (replaced with `"unknown"` on mismatch) |
| `:example_query` | One concrete example the LLM can adapt. | 2048 bytes |
| `:syntax_notes` | Short prose on quoting, reserved words, dialect pitfalls. | 1024 bytes |
| `:error_patterns` | `[%{pattern: Regex.t, hint: binary}]` — matched against execution errors so the LLM can self-correct. | 20 entries |
| `:capabilities` | Per-feature gate: `:generation`, `:optimization`, `:explanation`. Omit to default all three to `true`. | — |

### Trust boundary

Untrusted adapters get only `:language` plumbed into the LLM prompt —
`:syntax_notes`, `:example_query`, and `:error_patterns` are discarded so a
compromised or adversarial adapter cannot inject prompt text. The built-in
Ecto adapter (and its per-dialect wrappers) is always trusted. External
adapters opt in via:

```elixir
config :lotus, :trusted_source_adapters, [MyApp.Adapters.Echo]
```

Treat the trusted list as a security surface: every entry has the ability to
steer LLM output. Keep it short and owned by first-party code.

### Capability gates

Declare which AI features your adapter supports via `:capabilities`. Adapters
that omit the key opt into all three. For declared-unsupported features,
`Lotus.AI.supports?/2` returns `false` and `Lotus.AI.unsupported_reason/2`
surfaces the adapter-declared reason (replaced with a generic fallback for
untrusted adapters). UIs should gate feature buttons per-source via these
functions — `Lotus.AI.enabled?/0` is a global on/off and insufficient for
per-source decisions.

## Editor Configuration

Optional `editor_config/1` provides keywords, types, function completions, and
context boundaries for the web UI's editor:

```elixir
@impl true
def editor_config(_state) do
  %{
    language: "sql",
    keywords: ~w(PREWHERE FINAL SAMPLE SETTINGS FORMAT ENGINE),
    types:    ~w(UInt8 UInt64 Float64 Array LowCardinality Nullable),
    functions: [
      %{name: "uniq",      detail: "Approx distinct count", args: "(column)"},
      %{name: "arrayJoin", detail: "Unpack array to rows",  args: "(array)"},
      %{name: "toDate",    detail: "Convert to Date",       args: "(value)"}
    ],
    context_boundaries: ~w(prewhere final sample settings format)
  }
end
```

Fields:

- `language` — parser to use on the JS side (`"sql"` for all SQL dialects, or
  your own language identifier for custom editors)
- `keywords` — dialect-specific keywords merged with standard keywords
- `types` — dialect-specific type names
- `functions` — name + description + argument template
- `context_boundaries` — keywords that mark clause boundaries for
  context-aware completions (e.g. ClickHouse's `PREWHERE` is treated like
  `WHERE` for column suggestions)

For large function lists, extract into a dedicated `EditorConfig` submodule
(see `lotus_clickhouse` for an example with 300+ functions).

## A Note on the "schema" Word

Lotus's surface uses "schema" for two distinct concepts historically — in
v1.0 we swept the column-definition sense out of public docs and
identifiers, keeping only the namespace sense in callback names where the
SQL-ecosystem convention is load-bearing.

### What "schema" now means in Lotus

- **Namespace** — the SQL "database schema" (`information_schema.schemata`).
  Callback names `list_schemas/1`, `list_tables/3`, `default_schemas/1`,
  `resolve_table_namespace/3`, the `{schema, table}` tuple returned from
  `list_tables/3`, and the `schema` parameter on `example_query/3` all use
  this sense. Non-SQL adapters with a flat namespace return `[]` from
  `list_schemas/1`.

### Deliberately retained "schema" uses

These are **not** the column-definition sense — they are a different
established meaning and are kept for recognizability:

- `@callback schema() :: keyword()` on `Lotus.AI.Action` and
  `nimble_to_json_schema` on `Lotus.AI.Tool` — JSON Schema / NimbleOptions
  sense.
- Telemetry events `[:lotus, :schema, :introspection, :*]` — industry-
  standard "schema introspection" terminology.
- `:schema` cache profile on `Lotus.Config` — refers to the introspection-
  cache namespace (namespace sense).
- `Lotus.AI.SchemaOptimizer` module — internal; conventional DB-tooling
  terminology for the routine that picks which tables to analyze.
- `Lotus.Schema` module — introspection facade (list / describe / resolve).

### What got renamed

- `get_table_schema/3` → `describe_table/3` (public + callback). This
  callback's "schema" meant column definitions — renamed for clarity.
- `resolve_table_schema/3` → `resolve_table_namespace/3` (callback). The
  "schema" here was the namespace; the new name makes the intent explicit
  and avoids collision with the column-definitions reading.
- `Lotus.AI.Conversation.schema_context` field → `source_context`
  (internal). The field stores tables the AI has analyzed — "source
  context" is the accurate term now that non-SQL sources are first-class.
- `Lotus.AI.Conversation.update_schema_context/2` →
  `update_source_context/2` (internal).
- Optimization prompt type enum: `"schema"` → `"structure"` in suggestion
  JSON contract. LLMs now respond with
  `{"type": "structure", ...}` for schema-reshaping suggestions. The
  previous `"schema"` value is a v1.0-only breaking change; pre-v1
  responses are invalid.

## Registration

Custom adapters are registered via `:source_adapters`:

```elixir
config :lotus,
  source_adapters: [MyApp.Adapters.MSSQL, MyApp.Adapters.Elasticsearch]
```

**Resolution order.** When the resolver wraps a `:data_sources` entry:

1. External adapters (from `:source_adapters`), in list order
2. Built-in per-dialect adapters (`Adapters.Postgres`, `Adapters.MySQL`,
   `Adapters.SQLite3`)
3. Generic Ecto fallback (`Adapters.Ecto` with `Default` dialect)

The first adapter whose `can_handle?/1` returns `true` wins. External adapters
can override built-in handling for a given Ecto adapter if needed.

## Custom Resolvers

Both extension points feeding the adapter pipeline are pluggable behaviours:

- `Lotus.Source.Resolver` — resolves repo opts into `%Adapter{}` structs
- `Lotus.Visibility.Resolver` — loads schema / table / column visibility rules

Both ship with static defaults (`Lotus.Source.Resolvers.Static`,
`Lotus.Visibility.Resolvers.Static`) that read from application config. Custom
implementations let you load sources and rules from a database, registry, or
external service at runtime without forking Lotus.

See the [Custom Resolvers guide](custom-resolvers.md) for contracts, full
`Agent`- and ETS-backed examples, and testing guidance.

## References

- [`test/support/in_memory_adapter.ex`](../test/support/in_memory_adapter.ex)
  — first-party non-SQL reference adapter (DSL-map payloads, capability gates,
  ai_context) shipped in Lotus's own test suite.
- [`lotus_elasticsearch`](https://github.com/elixir-lotus/lotus_elasticsearch) —
  real-world non-Ecto adapter against the Elasticsearch Query DSL.
- [`lotus_clickhouse`](https://github.com/elixir-lotus/lotus_clickhouse) —
  external Ecto-backed adapter with a large `editor_config`.
