# Source Adapters

## Overview

Source adapters wrap data sources behind a uniform callback interface so the
Lotus execution pipeline does not depend on any particular database driver or
connection strategy. Every data source — whether it is an Ecto repo, a raw
database connection, or an external REST / DSL engine — is represented as a
`%Lotus.Source.Adapter{}` struct that the runner, preflight, cache, and
introspection modules all accept identically.

`Lotus.Source` is a public facade — not a behaviour. It provides convenience
functions (`resolve!/2`, `list_sources/0`, `get_source!/1`, `default_source/0`,
`source_type/1`, `supports_feature?/2`, `hierarchy_label/1`, `example_query/3`,
`query_language/1`, `editor_config/1`, `limit_query/3`,
`supported_filter_operators/1`, `prepare_for_analysis/2`) that accept adapter
structs, source-name strings, or repo modules and resolve lazily as needed.

For SQL databases backed by Ecto, per-dialect adapter modules
(`Lotus.Source.Adapters.Postgres`, `Lotus.Source.Adapters.MySQL`,
`Lotus.Source.Adapters.SQLite3`) handle dialect-specific behaviour. External
adapters for other databases or non-SQL data sources are named in their
`data_sources` entry (`%{adapter: MyAdapter, ...}`) or registered via the
`:source_adapters` config — see [Registration](#registration).

## How It Works

The adapter struct carries four fields:

| Field | Type | Description |
|---|---|---|
| `name` | `String.t()` | Human-readable identifier (e.g. `"main"`, `"warehouse"`) |
| `module` | `module()` | The module implementing `Lotus.Source.Adapter` callbacks |
| `state` | `term()` | Opaque connection state managed by the adapter (e.g. an Ecto.Repo module) |
| `source_type` | `atom()` | Database kind — `:postgres`, `:mysql`, `:sqlite`, `:other`, or any atom an external adapter declares |

When a query is executed, Lotus asks the configured **source resolver** to turn
a source name (or module) into an `%Adapter{}` struct. An entry that names its
adapter — `%{adapter: MyAdapter, ...}`, the canonical form — is handed straight
to that module's `wrap/2`. Any other entry is offered to every registered
adapter's `can_handle?/1`, and exactly one must claim it. From that point every
pipeline stage dispatches through `Lotus.Source.Adapter` helpers, which pass
`adapter.state` as the first argument to the adapter module's callbacks.

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
  adapter: MyApp.Adapters.Echo,   # module that owns this body's shape
  body:    "SELECT * FROM t",     # adapter-native payload (term())
  params:  [],                    # bound values — list or map
  meta:    %{}                    # adapter-specific metadata
}
```

The field carrying the query is `:body`, not `:text`. It is deliberately typed
`term()` — SQL text for Ecto-backed adapters, a decoded JSON map for
Elasticsearch, a DSL AST for other engines. Core never inspects it. The
pipeline is a series of pure `statement -> statement` transforms; adapters
return new structs rather than mutating in place.

`:params` is a **list** for positional binds, in the order the driver expects,
or a **map** for engines with named binds (`%{"since" => ~D[2026-01-01]}`),
where ordering is meaningless. Adapters that inline values into `:body` leave
it as `[]`.

Build one with `Lotus.Query.Statement.new/2` (`:body` is the only enforced
key):

```elixir
statement = Lotus.Query.Statement.new("SELECT * FROM users WHERE id = $1", [42])
```

Core reserves two `:meta` keys; everything else in the map belongs to the
adapter:

- `:count_spec` — placed by `apply_pagination/3` when the caller requested
  `count: :exact` and the adapter uses Strategy B (separate count query).
  Shape: `%{query: adapter-native, params: list()}`. Lotus core runs it
  through the same adapter. See "Exact counts" below.
- `:search_path` — reserved for schema-isolation hints. Callers pass
  `:search_path` as an option (it reaches `apply_pagination/3` and
  `execute_query/4` in `opts`); adapters must not repurpose the meta key.

### Pipeline order

Where each callback fires, for a stored query executed through
`Lotus.run_query/2`:

1. `transform_statement/2` — in `Lotus.Storage.Query.compile/2`, before any
   `{{var}}` is extracted. `statement.params` is `[]` here.
2. `substitute_variable/5` / `substitute_list_variable/5` — one call per
   variable, folded over the statement by the same compile step.
3. `transform_bound_query/3` — after binding, values now visible.
4. `apply_filters/3`, then `apply_sorts/3` — filter and sort column names are
   run through `validate_identifier/3` and operators through
   `supported_filter_operators/1` before dispatch.
5. `apply_pagination/3` — sees a statement that already carries filters and
   sorts.
6. `sanitize_query/3` — inside `Lotus.Runner.run_statement/3`, after the
   `:before_query` middleware may have rewritten the statement.
7. `needs_preflight?/2` → `extract_accessed_resources/2` — visibility preflight.
8. `execute_query/4` — the driver boundary.

## Exact counts — two adapter strategies

When the caller requests `count: :exact`, the adapter picks one of two
strategies to surface the pre-pagination total:

**Strategy A — inline count**, for engines where the count comes back with the
data. `execute_query/4` includes `:total_count` directly in its result map:

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
config (`Lotus.Source.Resolvers.Static` and
`Lotus.Visibility.Resolvers.Static`).

`:allow_unrestricted_resources` is also a **reserved key inside a source's own
config map**, where it overrides the global flag for that source in both
directions — `true` opts a single source in under a strict global default,
`false` keeps one source locked down under a permissive one:

```elixir
config :lotus,
  allow_unrestricted_resources: false,
  data_sources: %{
    "main"   => MyApp.Repo,
    "search" => %{
      adapter: MyApp.Adapters.Elasticsearch,
      url: "http://localhost:9200",
      allow_unrestricted_resources: true
    }
  }
```

## Building a Custom Adapter

Two paths, depending on whether your data source uses Ecto.

### A. Ecto-backed adapter (new SQL dialect)

Use this when Ecto already ships a driver for the database (e.g. `Tds` for
MSSQL) but Lotus does not ship a built-in dialect for it.
[`lotus_clickhouse`](https://github.com/elixir-lotus/lotus_clickhouse) is a
shipped example of this path.

1. Write a **Dialect module** implementing `Lotus.Source.Adapters.Ecto.Dialect`.
   The dialect encapsulates all SQL-specific behaviour (dialect-specific
   placeholder syntax, identifier quoting, EXPLAIN variant, introspection
   queries, built-in deny rules). `Lotus.Source.Adapters.Ecto.Dialect` is a
   **public, documented contract** — external SQL adapters are expected to
   implement it rather than the universal behaviour directly.
2. Write an **adapter module** that pulls in the shared Ecto machinery via
   `use Lotus.Source.Adapters.Ecto, dialect: ...`. The macro injects default
   implementations for every `Lotus.Source.Adapter` callback, delegating to
   the dialect where appropriate. All callbacks are `defoverridable`.
3. **Register** the adapter module in `:source_adapters`. The macro-generated
   `can_handle?/1` claims any repo whose `__adapter__/0` equals your dialect's
   `ecto_adapter/0`, so `data_sources` entries stay plain repo modules.

```elixir
defmodule MyApp.Dialects.MSSQL do
  @behaviour Lotus.Source.Adapters.Ecto.Dialect

  alias Lotus.Query.Statement

  # -- Identity ---------------------------------------------------------------
  @impl true
  def source_type, do: :mssql

  @impl true
  def ecto_adapter, do: Ecto.Adapters.Tds

  @impl true
  def query_language, do: "sql:tsql"

  @impl true
  def limit_query(%Statement{body: body} = statement, limit),
    do: %{statement | body: "SELECT TOP #{limit} * FROM (#{body}) AS t"}

  # -- Transaction & session --------------------------------------------------
  # execute_in_transaction/3, set_statement_timeout/2, set_search_path/2

  # -- Error handling ---------------------------------------------------------
  # format_error/1

  # -- SQL generation ---------------------------------------------------------
  # quote_identifier/1, param_placeholder/3, limit_offset_placeholders/2,
  # apply_filters/2, apply_sorts/2, query_plan/3

  # -- Visibility & deny rules -----------------------------------------------
  # builtin_denies/1, builtin_schema_denies/1, default_schemas/1

  # -- Introspection ----------------------------------------------------------
  # list_schemas/1, list_tables/3, describe_table/3, resolve_table_namespace/3
end

defmodule MyApp.Adapters.MSSQL do
  use Lotus.Source.Adapters.Ecto, dialect: MyApp.Dialects.MSSQL
end
```

The macro asserts at compile time that `:dialect` is a module implementing
`Lotus.Source.Adapters.Ecto.Dialect` (skipped when the dialect is still being
co-compiled, where Elixir's own `@behaviour` warnings catch mismatches).

Two SQL primitives that were universal callbacks before v1 —
`param_placeholder/3` and `limit_offset_placeholders/2` — live on the dialect
only. They are prepared-statement details, and nothing outside the Ecto path
calls them.

#### Dialect callbacks

Callbacks are organized by category. All required callbacks must be
implemented; optional callbacks have sensible defaults.

`set_statement_timeout/2` and `set_search_path/2` are optional. Engines with
no session-level timeout or schema search path omit them entirely rather than
defining no-op clauses; Lotus falls back to the driver-level `:timeout` and
ignores a caller-supplied `:search_path` for that source.

**Required:**

| Callback | Category |
|---|---|
| `source_type/0` | Identity |
| `ecto_adapter/0` | Identity |
| `query_language/0` | Identity |
| `limit_query/2` | Identity |
| `execute_in_transaction/3` | Transaction & session |
| `format_error/1` | Error handling |
| `quote_identifier/1` | SQL generation |
| `param_placeholder/3` | SQL generation |
| `limit_offset_placeholders/2` | SQL generation |
| `apply_filters/2` | SQL generation |
| `apply_sorts/2` | SQL generation |
| `query_plan/3` | SQL generation |
| `builtin_denies/1` | Visibility & deny rules |
| `builtin_schema_denies/1` | Visibility & deny rules |
| `default_schemas/1` | Visibility & deny rules |
| `list_schemas/1` | Introspection |
| `list_tables/3` | Introspection |
| `describe_table/3` | Introspection |
| `resolve_table_namespace/3` | Introspection |

**Optional** (defaults supplied by `Lotus.Source.Adapters.Ecto`) — the exact
list in `@optional_callbacks` on `Lotus.Source.Adapters.Ecto.Dialect`:

| Callback | Category | Default when not implemented |
|---|---|---|
| `set_statement_timeout/2` | Transaction & session | Not called; Lotus relies on the driver-level `:timeout` passed to `execute_query/4` |
| `set_search_path/2` | Transaction & session | Not called; a caller-supplied `:search_path` is ignored for that source |
| `supports_feature?/1` | Identity | `false` for every feature |
| `hierarchy_label/0` | Identity | `"Tables"` |
| `example_query/2` | Identity | Generic `SELECT value_column FROM table` |
| `editor_config/0` | Editor | `%{language: "sql", keywords: [], types: [], functions: [], context_boundaries: []}` |
| `ai_context/0` | AI | Generic-SQL context synthesized from `query_language/0`, with an empty `:error_patterns` list |
| `extract_accessed_resources/2` | Visibility | `{:unrestricted, "dialect ... does not implement extract_accessed_resources/2"}` — visibility is **not** enforced until you implement it |
| `needs_preflight?/1` | Visibility | The Ecto adapter's SQL heuristic: `false` for statements starting with `EXPLAIN`, `SHOW` or `PRAGMA`, `true` otherwise |
| `transform_statement/1` | Statement rewriting | Statement unchanged |
| `db_type_to_lotus_type/1` | Type mapping | `:text` |

Statement-carrying dialect callbacks (`apply_filters/2`, `apply_sorts/2`,
`query_plan/3`, `limit_query/2`, `transform_statement/1`,
`needs_preflight?/1`, `extract_accessed_resources/2`) take and return
`%Lotus.Query.Statement{}`, where `statement.body` is always SQL text and
`statement.params` the bound values in driver order.

### B. Non-Ecto adapter (REST, document store, DSL)

Use this for data sources that do not use Ecto at all — Elasticsearch, Mongo,
a REST API.
[`lotus_elasticsearch`](https://github.com/elixir-lotus/lotus_elasticsearch)
is a shipped example of this path.

Implement `Lotus.Source.Adapter` directly. Lotus ships a first-party reference
implementation in its own test suite at
[`test/support/in_memory_adapter.ex`](../test/support/in_memory_adapter.ex) —
an in-memory DSL-map adapter that exercises the full contract. A copy of it
makes a useful starting point for a new adapter.

The compiler only demands the nine callbacks that have no default —
`execute_query/4`, `transaction/3`, `list_tables/3`, `describe_table/3`,
`builtin_denies/1`, `health_check/1`, `disconnect/1`, `format_error/2` and
`source_type/1`. Everything else is optional with a documented default (see
[Required vs Optional Callbacks](#required-vs-optional-callbacks)), but a
useful adapter implements well beyond the minimum — in particular
`extract_accessed_resources/2`, without which every statement is blocked by
preflight unless the operator opts the source out of visibility enforcement.

Below is an abbreviated stub — see the in-memory adapter for full
implementations and the DSL-to-rows executor.

```elixir
defmodule MyApp.Adapters.Echo do
  @behaviour Lotus.Source.Adapter

  # -- Registration -----------------------------------------------------------
  # `wrap/2` receives the whole `data_sources` entry and returns the struct.
  # `can_handle?/1` is only consulted for entries that do NOT name their
  # adapter module — see "Registration" below.
  @impl true
  def can_handle?(%{adapter: :echo}), do: true
  def can_handle?(_), do: false

  @impl true
  def wrap(name, config) when is_binary(name) and is_map(config) do
    %Lotus.Source.Adapter{
      name: name,
      module: __MODULE__,
      state: config,
      source_type: :echo
    }
  end

  # -- Query execution --------------------------------------------------------
  # Core unwraps the statement here: `body` is `statement.body` and `params`
  # is `statement.params`, whatever your query language makes of them. Return
  # a result map with :columns, :rows, :num_rows (plus :total_count when you
  # use the inline count strategy) — Lotus wraps it into %Lotus.Result{}.
  @impl true
  def execute_query(_state, body, params, _opts) do
    {:ok,
     %{
       columns: ["statement", "param_count"],
       rows: [[inspect(body), length(params)]],
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
  def query_plan(_state, _statement, _opts), do: {:ok, nil}

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

  # -- Identity & presentation ------------------------------------------------
  @impl true
  def source_type(_state), do: :echo

  @impl true
  def supports_feature?(_state, _feature), do: false

  @impl true
  def query_language(_state), do: "echo:dsl"

  @impl true
  def editor_config(_state),
    do: %{language: "echo:dsl", keywords: [], types: [], functions: [], context_boundaries: []}

  @impl true
  def db_type_to_lotus_type(_state, _db_type), do: :text
end
```

Register it and use it like any other source. The canonical entry names the
adapter module outright, so no `:source_adapters` registration is needed. This
adapter does not implement `extract_accessed_resources/2`, so preflight would
block every statement — the source opts out of visibility enforcement
explicitly:

```elixir
config :lotus,
  data_sources: %{
    "echo" => %{
      adapter: MyApp.Adapters.Echo,
      allow_unrestricted_resources: true
    }
  }

{:ok, result} = Lotus.run_statement("hello", [1, 2, 3], repo: "echo")
# result.rows #=> [["\"hello\"", 3]]
```

A real adapter implements `extract_accessed_resources/2` instead of opting
out.

## Required vs Optional Callbacks

The full `Lotus.Source.Adapter` contract is 41 callbacks, nine of which are
required. Most non-SQL adapters implement far more than the minimum; the
optional list is for adapters that legitimately cannot support a feature.

**Required** — no default; the compiler warns if you omit one:

| Callback | Purpose |
|---|---|
| `execute_query(state, body, params, opts)` | The driver boundary. Returns `{:ok, %{columns:, rows:, num_rows:}}`, optionally with `:total_count`. |
| `transaction(state, fun, opts)` | Run `fun` (arity 1, receives `state`) inside a transaction. |
| `list_tables(state, schemas, opts)` | `{:ok, [{schema_or_nil, table}]}`. `opts` carries `:include_views`. |
| `describe_table(state, schema, table)` | `{:ok, [column_def]}` — `%{name, type, nullable, default, primary_key}`. |
| `builtin_denies(state)` | Always-hidden relations, as `{schema_pattern, table_pattern}` tuples. |
| `health_check(state)` | `:ok` or `{:error, reason}`. |
| `disconnect(state)` | Release resources. |
| `format_error(state, error)` | Driver error → human-readable string. |
| `source_type(state)` | The source-type atom. Open — any atom your adapter declares. |

**Optional with documented defaults** — omit when not applicable. This table
mirrors `@optional_callbacks` in `Lotus.Source.Adapter`:

| Callback | Default | When to implement |
|---|---|---|
| `sanitize_query/3` | `:ok` | When you need to block specific statement shapes (read-only enforcement, destructive-op blocking). `opts` carries `:read_only`. |
| `transform_statement/2` | statement unchanged | Language-specific rewrites of the stored template, applied **before** `{{var}}` placeholders are extracted (`params` is still `[]`). |
| `transform_bound_query/3` | statement unchanged | Rewrites applied **after** variable binding (when values are visible). |
| `apply_pagination/3` | statement unchanged | Page a statement in your source's native syntax. `opts` carries `:limit` (required), `:offset`, `:count` and `:search_path`. |
| `needs_preflight?/2` | `true` | Skip preflight for read-only introspection statements (`EXPLAIN`, `SHOW`, `PRAGMA`, etc.). |
| `substitute_variable/5` | `{:error, :unsupported}` | Support `{{var}}` in stored queries. **Security boundary — see below.** |
| `substitute_list_variable/5` | `{:error, :unsupported}` | Support list variables. |
| `validate_statement/3` | `:ok` (trust-on-execute) | Validate a draft via an engine's `_validate` endpoint without executing. |
| `parse_qualified_name/2` | `{:ok, [name]}` | Adapters with a two-level namespace (`schema.table`, `db.collection`). See [Relations are two-level](#relations-are-two-level). |
| `validate_identifier/3` | `:ok` (permissive) | Enforce your query language's identifier grammar. |
| `supported_filter_operators/1` | all of `Lotus.Query.Filter.operators/0` | Declare the subset of filter operators your `apply_filters/3` actually handles. |
| `extract_accessed_resources/2` | `{:unrestricted, reason}` | Return `{:ok, MapSet}` of accessed `{schema, table}` tuples so visibility rules apply. **See below.** |
| `ai_context/1` | `{:error, :ai_not_supported}` | Opt into Lotus.AI — language identifier, example query, syntax notes, error patterns, capability gates. |
| `prepare_for_analysis/2` | `{:error, :unsupported}` | Produce a runnable statement for `query_plan/3` analysis — strips `[[ ... ]]`, neutralizes `{{var}}`. |
| `hierarchy_label/1` | `"Tables"` | UI label for the top-level hierarchy (e.g. `"Indices"` for Elasticsearch). |
| `example_query/3` | generic `SELECT` | Source-native example for the query editor's placeholder text. |
| `table_stats/3` | `{:error, :unsupported}` | Relation statistics. Without it, core falls back to `SELECT COUNT(*)`, which only suits SQL sources. |
| `limit_query/3` | statement unchanged | Cap a statement at a row limit for the UI's preview affordance — `%Statement{}` in, `%Statement{}` out. |
| `list_schemas/1` | `{:ok, []}` | Sources with a namespace level. Flat sources omit it. |
| `resolve_table_namespace/3` | `{:ok, nil}` | Resolve which namespace holds a table. |
| `default_schemas/1` | `[]` | Namespaces browsed when the caller names none. |
| `builtin_schema_denies/1` | `[]` | Namespaces always hidden (system catalogues). |
| `quote_identifier/2` | identifier unchanged | Quote an identifier. Languages without quoting omit it. |
| `apply_filters/3` | statement unchanged | Bake runtime filters into the statement. |
| `apply_sorts/3` | statement unchanged | Bake runtime sorts into the statement. |
| `query_plan/3` | `{:ok, nil}` | Execution plan, when the engine exposes one. Takes `(state, %Statement{}, opts)` — the statement carries its own bound values in `:params`, there is no separate params argument. Returning `{:ok, nil}` is legitimate for an engine with no plan. |
| `supports_feature?/2` | `false` | Declare capabilities. See `t:Lotus.Source.Adapter.feature/0`. |
| `db_type_to_lotus_type/2` | `:text` | Map engine column types onto Lotus value types. |
| `editor_config/1` | empty editor shape | Keywords, types and functions for editor completions. |
| `query_language/1` | `"sql"` | Declare the `family:dialect` identifier for your language. See [Query Language Identifiers](#query-language-identifiers). |
| `can_handle?/1` | not consulted | Claim a `data_sources` entry that does not name your module. |
| `wrap/2` | — | Build the `%Adapter{}` from a `data_sources` entry. Required in practice: the resolver calls it for every entry it routes to your adapter. |

Two notes on that table. `can_handle?/1` and `wrap/2` are optional to the
compiler because an adapter can be constructed by hand (or by a custom
resolver), but any adapter registered through `:data_sources` needs `wrap/2`.
And a default that returns "nothing" is not always the safe choice:
`extract_accessed_resources/2` defaulting to `{:unrestricted, _}` means an
adapter that omits it enforces no visibility at all.

## Universal Callbacks

Five callbacks exist so non-SQL sources reach parity with the SQL path
instead of being special-cased in core:

- **`validate_statement(state, statement, opts)`** — can the engine parse and
  prepare this statement without running it? SQL adapters implement it with
  `EXPLAIN`; Elasticsearch uses `_validate`; an engine with no such endpoint
  omits the callback and inherits `:ok` (trust-on-execute). Callers
  neutralize unbound `{{var}}` placeholders first — adapters see the
  statement as-is.
- **`parse_qualified_name(state, name)`** — `{:ok, [component]}`, coarsest
  first, leaf last, at most two components. `"public.users"` →
  `["public", "users"]`; a flat index name → `["logs-2025-01"]`.
- **`validate_identifier(state, kind, value)`** — `kind` is `:schema`,
  `:table` or `:column`. Core calls this on filter and sort column names
  before dispatching them to `apply_filters/3` / `apply_sorts/3`; an
  identifier your adapter rejects raises `ArgumentError`. The default is
  permissive, so declare your grammar if user-supplied names reach your
  statement builder.
- **`supported_filter_operators(state)`** — the `Lotus.Query.Filter`
  operators your `apply_filters/3` actually handles. Core raises
  `Lotus.UnsupportedOperatorError` on anything outside the list rather than
  degrading silently, and `Lotus.Source.supported_filter_operators/1` gates
  the operator dropdown per source. The default is every operator in
  `Lotus.Query.Filter.operators/0`, so narrow it if you cannot implement them
  all.
- **`needs_preflight?(state, statement)`** — `false` for read-only
  introspection statements that touch no visible relation. Core no longer
  sniffs SQL prefixes; this callback owns the skip path. The built-in Ecto
  adapter keeps the `EXPLAIN` / `SHOW` / `PRAGMA` heuristic internally.

## Declaring Features

`supports_feature?(state, feature)` answers capability questions from core and
the built-in UI. The feature type is open — answer `false` for anything you do
not recognise (a catch-all clause) — but these atoms have defined meaning:

| Feature | Meaning |
|---|---|
| `:schema_hierarchy` | The source has a real namespace level above tables, so the UI shows a schema picker. False for flat sources (SQLite, Elasticsearch) and for MySQL, whose databases are configured per source. |
| `:search_path` | The source honours a session-level namespace search path, so a caller-supplied `:search_path` is meaningful. |
| `:arrays` | The query language has a first-class array type, so a list variable can bind as one value instead of N placeholders. |
| `:json` | The source can store and query JSON documents; the editor offers JSON-aware affordances. |
| `:make_interval` | SQL-specific: the engine has `make_interval`, so `INTERVAL '{{n}} days'` can be rewritten into a parameterized call instead of inlining the value. |
| `:dynamic_options` | A query against this source can return a flat list of values suitable for a variable's dropdown, so the UI offers query-based option population. True for every SQL source; false where the language returns shaped documents rather than rows (Elasticsearch), and the user types the options by hand. |

`source_type/1` is likewise an open atom: `:postgres`, `:mysql`, `:sqlite`,
`:other`, or whatever your adapter declares (`:clickhouse`,
`:elasticsearch`). Core never matches on an exhaustive list.

## The Security Boundaries

Two callbacks are **security boundaries**. Get them wrong and you open
injection or authorization gaps.

### 1. `substitute_variable/5` — adapter owns injection safety

When a stored query contains `{{var_name}}`, `Lotus.Storage.Query.compile/2`
folds each variable through your adapter — `substitute_variable(state,
statement, var_name, value, type)` for a scalar, `substitute_list_variable(
state, statement, var_name, values, type)` for a list — and each call returns
`{:ok, %Statement{}}` or `{:error, reason}`. The value arrives already cast by
core; `type` is the resolved Lotus type atom (`:integer`, `:uuid`, …), which
you may ignore. Core never touches placeholders or param arrays itself. The
adapter decides how to embed the value:

- **SQL prepared-statement adapters** (`Lotus.Source.Adapters.Ecto`) append a
  placeholder (`$1`, `?`, …) to `statement.body` and push the value into
  `statement.params`. The database driver handles binding and escaping.
- **JSON / DSL adapters** (Elasticsearch, Mongo) have no prepared-statement
  concept. They inline values directly into `statement.body`. **This is the
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

## Query Language Identifiers

`query_language/1` returns a `family:dialect` identifier. The family names
the shape of the statement; the dialect names the engine that speaks it.

| Adapter | `query_language/1` |
|---|---|
| Postgres | `sql:postgres` |
| MySQL | `sql:mysql` |
| SQLite | `sql:sqlite` |
| ClickHouse | `sql:clickhouse` |
| Elasticsearch | `json:elasticsearch` |
| `Default` dialect | `sql` (bare, no colon) |

Two things read this value, and they read it differently:

- **Saved queries.** `Lotus.Storage.Query` records the identifier in its
  `:query_language` column when a query is saved. At execution,
  `Lotus.run_query/2` compares it to the resolved source's identifier and
  refuses to run on a mismatch, naming both languages and the source. The
  comparison is **exact, not family-level**: `sql:postgres` and
  `sql:clickhouse` share a family but are not interchangeable, and
  repointing a source from one to the other is the case the check exists
  to catch. A query saved with no identifier (`NULL`) runs anywhere, which
  is how every row predating the column behaves.
- **AI prompts.** Only the **family** is used, as the markdown fence label.
  See [Fences](#fences).

Keep the identifier stable. Changing it on a shipped adapter invalidates
every saved query that recorded the old value.

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
     generation_notes:
       "- Name the fields you need after `from`.\n" <>
         "- Add `take n` unless the user asked for everything.",
     read_only_notes:
       "**IMPORTANT:** Never emit `put`, `patch` or `drop` pipelines. " <>
         "If asked to, respond with: \"UNABLE_TO_GENERATE: [reason]\"",
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
| `:generation_notes` | How to shape a good query for this source. Optional. | 1024 bytes |
| `:read_only_notes` | Which operations this source treats as writes, and so must never be generated. Optional. | 1024 bytes |
| `:capabilities` | Per-feature gate: `:generation`, `:optimization`, `:explanation`. Omit to default all three to `true`. | — |

### What belongs in which field

Core owns prompt **structure**; your adapter owns prompt **content** about
its own language. The split follows the enforcement: `sanitize_query/3` is
already your callback, so you — not core — decide what counts as a write.

| Core writes it | You write it |
|---|---|
| The workflow and the tool list | `:language` |
| `{{var}}` / `[[optional]]` template rules | `:example_query` |
| The `UNABLE_TO_GENERATE` protocol | `:syntax_notes` |
| The fence protocol | `:generation_notes` |
| A generic default for each of your two notes fields | `:read_only_notes` |

Your notes render **in place of** core's defaults, never appended after
them. Omit a field and core's generic text is used, so there is no need to
restate anything language-agnostic.

Put syntax in `:syntax_notes` and prohibitions in `:read_only_notes`. They
are different jobs: core's default read-only text is deliberately generic
("never create, modify or delete data or schema") because only you can name
the operations that do that in your language. If your source's write paths
are `_delete_by_query` and `_update_by_query`, say so in `:read_only_notes`
— core cannot know it.

The tool names your prose refers to (`list_tables`, `describe_table`,
`execute_statement`, `validate_statement`) are part of this contract. A hint
like "List available indices via `list_tables`" relies on that name being
stable, so treat the tool list as API.

### Fences

Core asks the LLM for the statement inside a fence labelled with your
language **family** — the part of `:language` before the colon. A
`:language` of `json:elasticsearch` produces a ` ```json ` fence. Editors
and markdown renderers know `json`; they do not know `json:elasticsearch`.
The extractor accepts any label, so a new family needs no change in core.

### Trust boundary

Untrusted adapters get only `:language` plumbed into the LLM prompt —
`:syntax_notes`, `:example_query`, `:error_patterns`, `:generation_notes`
and `:read_only_notes` are discarded so a compromised or adversarial adapter
cannot inject prompt text. The two notes fields are **dropped, not blanked**:
core falls back to its own default text. An empty `:read_only_notes` taken
literally would leave the prompt with no read-only instruction at all, which
would let an untrusted adapter weaken the guard by supplying a blank. The built-in
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
    language: "sql:clickhouse",
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

Required fields:

- `language` — the query-language identifier (`"sql:postgres"`,
  `"json:elasticsearch"`, …). Drives CodeMirror language selection.
- `keywords`, `types` — flat lists feeding the "complete any keyword anywhere"
  fallback (used when `:context_schema` is absent) and the AI prompt pipeline.
- `functions` — `%{name, detail, args}` entries for signature help.
- `context_boundaries` — keywords that mark clause boundaries for
  context-aware completions (e.g. ClickHouse's `PREWHERE` is treated like
  `WHERE` for column suggestions). SQL-only; ignored for JSON DSLs.

Optional fields:

- `dialect_spec` — SQL tokenizer options, forwarded verbatim (camelCased) to
  CodeMirror 6's `SQLDialect.define()`, so an external SQL adapter reaches
  tokenization parity with the built-in grammars. Only meaningful for SQL
  languages; an adapter that sits on a built-in CM6 dialect (Postgres, MySQL,
  SQLite, MSSQL, MariaSQL, Cassandra, PLSQL) omits it and gets that grammar.
  Keys mirror `@codemirror/lang-sql`'s `SQLDialectSpec` — see
  `t:Lotus.Source.Adapter.dialect_spec/0`.

  ```elixir
  dialect_spec: %{
    identifier_quotes: "`",
    hash_comments: true,
    double_quoted_strings: false,
    case_insensitive_identifiers: true
  }
  ```

- `context_schema` — structural schema for a JSON DSL, driving parent-aware
  completion (only `must` / `should` / `filter` inside Elasticsearch's `bool`,
  field names inside `match`). Omit it for SQL adapters; omitting it in a JSON
  DSL adapter degrades the editor to flat keyword suggestions at every key
  position. `:children` values are either a list of valid child keys or one of
  the marker atoms `:fields`, `:array_of_query`, `:named_aggregation`,
  `:range_operators` — see `t:Lotus.Source.Adapter.context_schema/0`.

  ```elixir
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
  ```

Unknown top-level keys are dropped at the dispatch layer, and `:keywords`
(2000), `:types` (2000), `:functions` (500), `:context_schema.root` (200) and
`:context_schema.children` (500) are truncated past those limits with a
one-time `Logger.warning/1` per adapter — a large payload otherwise ships to
every editor session.

For large function lists, extract into a dedicated `EditorConfig` submodule
(see `lotus_clickhouse` for an example with 300+ functions).

## Relations are Two-Level

Everywhere Lotus names a resource it uses exactly two levels:
`{schema | nil, table}`. Visibility rules, deny lists, `describe_table/3`,
`resolve_table_namespace/3`, the preflight relation set and
`extract_accessed_resources/2` all speak this shape, and core never grows a
third element.

`nil` in the first position means unqualified — either a source with no
namespace concept (SQLite tables, Elasticsearch indices) or a name the
caller left unqualified.

If your engine has a **deeper** hierarchy, flatten everything above the leaf
into the schema part, keeping your query language's own separator:

| Engine shape | Lotus relation |
|---|---|
| `schema.table` | `{"schema", "table"}` |
| flat (`index`) | `{nil, "index"}` |
| `project.dataset.table` | `{"project.dataset", "table"}` |
| `catalog.schema.table` | `{"catalog.schema", "table"}` |

Your adapter owns the flattening, in `parse_qualified_name/2` and
`resolve_table_namespace/3`. Core treats the schema part as an opaque string
and compares it verbatim against visibility rules — so a deny rule a host
writes has to match the spelling your adapter emits. Document that spelling
in your adapter's README.

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
- `Lotus.AI.Conversation.update_source_context/2` →
  `update_source_context/2` (internal).
- Optimization prompt type enum: `"schema"` → `"structure"` in suggestion
  JSON contract. LLMs now respond with
  `{"type": "structure", ...}` for schema-reshaping suggestions. The
  previous `"schema"` value is a v1.0-only breaking change; pre-v1
  responses are invalid.

## Registration

A `:data_sources` entry takes one of three forms, and the form decides how the
default resolver finds the adapter.

**1. `%{adapter: Module, ...}` — the canonical form.** The named module is used
directly: no probing, no ambiguity, and the whole map is handed to its
`wrap/2` as state. Prefer it. The module must be loaded and export `wrap/2`,
or resolution raises with the offending entry.

```elixir
config :lotus,
  data_sources: %{
    "search" => %{adapter: MyApp.Adapters.Elasticsearch, url: "http://localhost:9200"}
  }
```

**2. An `Ecto.Repo` module.** Matched against the built-in Ecto adapters by the
repo's Ecto adapter — `Ecto.Adapters.Postgres` → `Lotus.Source.Adapters.Postgres`,
`Ecto.Adapters.MyXQL` → `MySQL`, `Ecto.Adapters.SQLite3` → `SQLite3` — falling
back to the generic `Lotus.Source.Adapters.Ecto` with the `Default` dialect.

**3. Any other term** (a map with no adapter module, a tuple, a tagged atom).
Offered to every module in `:source_adapters` plus the built-in Ecto adapters
via `can_handle?/1`:

```elixir
config :lotus,
  source_adapters: [MyApp.Adapters.MSSQL, MyApp.Adapters.Echo]
```

**Exactly one adapter must claim the entry.** If several return `true` from
`can_handle?/1`, resolution **raises** rather than picking the first — the
error names the competing modules and tells the operator to settle it by
naming the adapter in the entry. If none claims it and the entry is an atom,
it falls back to the Ecto adapter; if none claims a non-atom entry,
resolution raises.

Probing is a convenience, not a priority list. An adapter whose
`can_handle?/1` is broad will collide with another one sooner or later — form
1 is the way out.

## Custom Resolvers

Both extension points feeding the adapter pipeline are pluggable behaviours:

- `Lotus.Source.Resolver` — resolves a source name or module into an `%Adapter{}` struct
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
- [`lotus_clickhouse`](https://github.com/elixir-lotus/lotus_clickhouse) —
  worked example of **path A**: an Ecto-backed adapter speaking SQL over HTTP,
  built from a dialect module plus a one-line
  `use Lotus.Source.Adapters.Ecto`, with a large `editor_config` and a
  `dialect_spec`.
- [`lotus_elasticsearch`](https://github.com/elixir-lotus/lotus_elasticsearch) —
  worked example of **path B**: a non-SQL adapter over the Elasticsearch JSON
  Query DSL. Shows inlined (escaped) variable substitution, the inline count
  strategy, `{:unrestricted, _}` visibility, and a `context_schema` for the
  editor.

Both packages were written against this guide; if something here disagrees
with `Lotus.Source.Adapter`, the behaviour module is the authority.
