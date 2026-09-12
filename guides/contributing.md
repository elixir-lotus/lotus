# Contributing to Lotus

Thank you for your interest in contributing to Lotus! This guide will help you get started with development and explain our contribution process.

## Getting Started

### Prerequisites

- **Elixir 1.18 or later** (`mix.exs` requires `~> 1.18`; CI runs 1.18, 1.19 and 1.20)
- **OTP 27 or later** (CI runs OTP 27.3.2 for Elixir 1.18/1.19 and OTP 29.0.2 for Elixir 1.20)
- **Docker** — the repo ships a `docker-compose.yml` with the PostgreSQL and MySQL services the test suite expects
- **SQLite 3** — provided by the `ecto_sqlite3` dependency; the database is a file under `priv/`
- Git

If you use [mise](https://mise.jdx.dev/), `mise.toml` pins the versions the
maintainers develop against (Elixir 1.20.1-otp-29, Erlang 29.0.2) — run
`mise install` and you are done.

### Database Services

`docker compose up -d` starts everything:

| Service | Image | Host port | Credentials |
|---------|-------|-----------|-------------|
| `db` (PostgreSQL) | `postgres:15.8` | `2345` | `postgres` / `postgres` |
| `mysql` | `mysql:8.0` | `3307` | `lotus` / `lotus` (root: `mysql`), database `lotus_test` |
| `adminer` | `adminer` | `8086` | web DB browser, optional |

The ports are deliberately non-standard so they do not collide with a local
PostgreSQL or MySQL install. `config/dev.exs` and `config/test.exs` point at
them. The MySQL test repo reads a `MYSQL_URL` environment variable and falls
back to `mysql://root:mysql@localhost:3307/lotus_test`.

### Development Setup

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/elixir-lotus/lotus.git
   cd lotus
   ```

2. **Install dependencies**
   ```bash
   mix deps.get
   ```

3. **Start the database services**
   ```bash
   docker compose up -d
   ```

4. **Set up the development databases**
   ```bash
   mix ecto.setup
   ```

   This runs `ecto.create` + `ecto.migrate` for all three dev repos
   (`Lotus.Test.Repo` on PostgreSQL, `Lotus.Test.MysqlRepo`, and
   `Lotus.Test.SqliteRepo`), creating:

   - PostgreSQL database `lotus_dev` with both the Lotus tables and sample data
   - MySQL database `lotus_test` with sample data
   - SQLite database `priv/lotus_dev.db` with e-commerce sample data

   `mix ecto.reset` drops and recreates them.

5. **Set up the test databases and run the tests**
   ```bash
   mix test.setup   # ecto.drop --quiet + ecto.create + ecto.migrate, in MIX_ENV=test
   mix test
   ```

   `mix test.setup` and `mix test` are both pinned to `MIX_ENV=test` by the
   `cli/0` callback in `mix.exs`, so no `MIX_ENV=` prefix is needed.

6. **Start exploring with interactive development**
   ```bash
   iex -S mix
   ```

   The development environment starts the PostgreSQL, MySQL and SQLite repos.
   You can immediately start experimenting:

   ```elixir
   # Run a statement against a named data source
   Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: "postgres")
   Lotus.run_statement("SELECT COUNT(*) FROM products", [], repo: "sqlite")

   # Inspect what is configured
   Lotus.list_data_source_names()
   #=> ["postgres", "mysql", "sqlite"]

   # Create and run a saved query
   {:ok, query} = Lotus.create_query(%{
     name: "Test Query",
     statement: "SELECT 1 AS test"
   })
   Lotus.run_query(query)
   ```

## Architecture Overview

Before making non-trivial changes it helps to understand how Lotus is organized and how a request flows through the system. This section is a map — not an exhaustive reference — and links to the modules you'll most often touch.

### Module Responsibilities

Everything lives under `lib/lotus/`. The library is roughly split into a public API surface, a query pipeline, storage, introspection, and a set of pluggable adapters.

**Public API and lifecycle**

- [`Lotus`](../lib/lotus.ex) — Top-level facade. `run_query/2`, `run_statement/3`, `create_query/1`, schema helpers, and dashboard helpers all entry through here.
- [`Lotus.Supervisor`](../lib/lotus/supervisor.ex) — Boots the configured cache adapter, starts a `Task.Supervisor` (used by dashboard card execution), and compiles the middleware pipeline.
- [`Lotus.Config`](../lib/lotus/config.ex) — Validates and caches application configuration (data sources, cache profiles, visibility rules, AI settings, middleware, adapter registration, resolvers) through a `NimbleOptions` schema.
- [`Lotus.Telemetry`](../lib/lotus/telemetry.ex) — Emits `:telemetry` events for query execution, schema introspection, and cache hits/misses.

**Query pipeline**

- [`Lotus.Query.Statement`](../lib/lotus/query/statement.ex) — The opaque carrier threaded through the whole pipeline: `:adapter`, `:body` (adapter-native term — SQL text, a JSON map, a DSL AST), `:params` (list for positional binds, map for named binds), and `:meta`.
- [`Lotus.Runner`](../lib/lotus/runner.ex) — Execution engine. Runs `:before_query` middleware, asks the adapter to sanitize the statement, invokes preflight, runs `:before_execute` middleware with the relations preflight found, executes inside a read-only transaction, and applies column-level visibility policies to the result.
- [`Lotus.Preflight`](../lib/lotus/preflight.ex) — Asks the adapter which relations a statement will touch before executing it (`EXPLAIN` for the Ecto adapter) and checks them against visibility rules.
- [`Lotus.Preflight.Relations`](../lib/lotus/preflight/relations.ex) — Process-local staging for relations discovered during preflight so the runner can reuse them when applying column policies.
- [`Lotus.Middleware`](../lib/lotus/middleware.ex) — Plug-style pipeline compiled into `:persistent_term`. Supports `:before_query`, `:before_execute`, `:after_query`, `:after_list_schemas`, `:after_list_tables`, `:after_describe_table`, `:after_list_relations`, and `:after_discover`.
- [`Lotus.Result`](../lib/lotus/result.ex) / [`Lotus.Result.Statistics`](../lib/lotus/result/statistics.ex) — The struct returned from query execution.
- [`Lotus.UnsupportedOperatorError`](../lib/lotus/unsupported_operator_error.ex) — Raised when a filter asks for an operator the adapter did not declare in `supported_filter_operators/1`. Silent degradation is not an option.

**Saved queries, dashboards, and visualizations**

- [`Lotus.Storage`](../lib/lotus/storage.ex) — CRUD for saved queries persisted through the application's `:storage_repo`.
- [`Lotus.Storage.Query`](../lib/lotus/storage/query.ex) — Schema for saved queries. `compile/2` and `compile!/2` thread a `%Statement{}` through a reduce loop, delegating each `{{variable}}` to the adapter's `substitute_variable/5`. Queries carry a `data_source` and an optional `query_language` (`sql:postgres`, `json:elasticsearch`).
- [`Lotus.Storage.SchemaCache`](../lib/lotus/storage/schema_cache.ex) — ETS-backed cache of column metadata used for type-aware value casting.
- [`Lotus.Storage.TypeCaster`](../lib/lotus/storage/type_caster.ex) / `TypeHandler` — Cast user values into parameters appropriate for the target source. The `column_info` map carries a resolved `%Lotus.Source.Adapter{}` under `:adapter`; type mapping is handled by the adapter's `db_type_to_lotus_type/2` callback,
which the Ecto adapter forwards to its dialect's `db_type_to_lotus_type/1`.
- [`Lotus.Dashboards`](../lib/lotus/dashboards.ex) — CRUD and orchestration for dashboards (cards, filters, filter mappings). Uses the task supervisor to fan out card execution.
- [`Lotus.Viz`](../lib/lotus/viz.ex) — CRUD and validation for per-query visualization configs.
- [`Lotus.Query.Filter`](../lib/lotus/query/filter.ex) / [`Lotus.Query.Sort`](../lib/lotus/query/sort.ex) — Runtime filter/sort structs that the adapter's `apply_filters/3` and `apply_sorts/3` inject into an already-prepared statement.
- `Lotus.Source.Adapters.Ecto.SQL.*` (`lib/lotus/source/adapters/ecto/sql/`) — Low-level SQL helpers (sanitizer, identifier quoting, filter/sort injectors, validator, transformer). These are Ecto-adapter internals, not part of the universal contract.

**Introspection and visibility**

- [`Lotus.Schema`](../lib/lotus/schema.ex) — `list_schemas/2`, `list_tables/2`, `describe_table/3`, `get_table_stats/3`, and `list_relations/2` across sources. Automatically applies visibility rules and runs the `:after_list_*` middleware.
- [`Lotus.Visibility`](../lib/lotus/visibility.ex) — Schema and table visibility, where **schema visibility takes precedence**, plus column policies applied to result rows. Together these are the three levels: schema, table, column.
- [`Lotus.Visibility.Policy`](../lib/lotus/visibility/policy.ex) — Per-column policy (`:omit`, `{:mask, ...}`, `:error`) that the runner applies to result rows.
- [`Lotus.Visibility.Resolver`](../lib/lotus/visibility/resolver.ex) — Behaviour for plugging in custom visibility resolution; the default lives in [`Lotus.Visibility.Resolvers.Static`](../lib/lotus/visibility/resolvers/static.ex) and is selected with the `:visibility_resolver` config key.

**Source adapter abstraction**

- [`Lotus.Source`](../lib/lotus/source.ex) — Public **facade** (not a behaviour) for data sources: `resolve!/2`, `list_sources/0`, `get_source!/1`, `default_source/0`, `source_type/1`, `supports_feature?/2`, `hierarchy_label/1`, `example_query/3`, `query_language/1`, `editor_config/1`, `limit_query/3`, `supported_filter_operators/1`, `prepare_for_analysis/2`, `name_from_module!/1`. Each accepts an adapter struct, a source name string, or a repo module.
- [`Lotus.Source.Adapter`](../lib/lotus/source/adapter.ex) — The universal behaviour **and** struct (`%Adapter{name, module, state, source_type}`) that represents a resolved data source. This is what flows through the query pipeline instead of raw repo modules. Most SQL-shaped callbacks are optional with safe defaults, so a non-SQL adapter implements roughly ten callbacks rather than thirty.
- [`Lotus.Source.Adapters.Ecto`](../lib/lotus/source/adapters/ecto.ex) — Macro provider (`use Lotus.Source.Adapters.Ecto, dialect: ...`) and generic fallback adapter for unknown Ecto repos.
- [`Lotus.Source.Adapters.Postgres`](../lib/lotus/source/adapters/postgres.ex) / [`MySQL`](../lib/lotus/source/adapters/mysql.ex) / [`SQLite3`](../lib/lotus/source/adapters/sqlite.ex) — Per-dialect adapter modules, each built with the `Ecto` macro.
- [`Lotus.Source.Adapters.Ecto.Dialect`](../lib/lotus/source/adapters/ecto/dialect.ex) — **Public** behaviour for SQL-dialect-specific callbacks (transaction handling, identifier quoting, introspection queries, placeholders, type mapping, `query_language/0`). This is what an external SQL engine implements.
- [`Lotus.Source.Adapters.Ecto.Dialects.Postgres`](../lib/lotus/source/adapters/ecto/dialects/postgres.ex) / [`MySQL`](../lib/lotus/source/adapters/ecto/dialects/mysql.ex) / [`SQLite3`](../lib/lotus/source/adapters/ecto/dialects/sqlite.ex) / [`Default`](../lib/lotus/source/adapters/ecto/dialects/default.ex) — Dialect implementations.
- [`Lotus.Source.Resolver`](../lib/lotus/source/resolver.ex) / [`Lotus.Source.Resolvers.Static`](../lib/lotus/source/resolvers/static.ex) — Behaviour and default implementation for resolving a name/module into an `%Adapter{}`, selected with the `:source_resolver` config key. An unresolvable name is an error — it never silently falls back to the default source.
- [`Lotus.Normalizer.Postgres`](../lib/lotus/normalizer/postgres.ex) / [`Lotus.Normalizer.MySQL`](../lib/lotus/normalizer/mysql.ex) — Normalize driver-specific result shapes into the `Lotus.Result` format.

**Caching**

- [`Lotus.Cache`](../lib/lotus/cache.ex) — Facade that dispatches to the configured cache adapter and emits telemetry. Supports namespaced keys, TTL, and tag-based invalidation. Result entries are tagged `"query:<id>"`, `"source:<name>"`, and — when a scope is given — `"scope:<digest>"`.
- [`Lotus.Cache.Adapter`](../lib/lotus/cache/adapter.ex) — Behaviour for cache backends (`get/1`, `put/4`, `delete/1`, `get_or_store/4`, `invalidate_tags/1`, `touch/2`, `spec_config/0`).
- [`Lotus.Cache.ETS`](../lib/lotus/cache/ets.ex) / [`Lotus.Cache.Cachex`](../lib/lotus/cache/cachex.ex) — Built-in backends. ETS is the zero-dependency default; Cachex is the advanced option.
- [`Lotus.Cache.Key`](../lib/lotus/cache/key.ex) / [`Lotus.Cache.KeyBuilder`](../lib/lotus/cache/key_builder.ex) — `Key` is a thin wrapper that delegates to the configured key builder. `KeyBuilder` is the behaviour (`discovery_key/2`, `result_key/4`) with a public `scope_digest/1` helper; swap it with `cache: %{key_builder: MyApp.KeyBuilder}`.

**Export and AI**

- [`Lotus.Export`](../lib/lotus/export.ex) — Converts `Lotus.Result` to CSV/JSON/JSONL (`to_csv/1`, `to_json/1`, `to_jsonl/1`), streams large CSV exports (`stream_csv/2`), and ZIPs a full dashboard export (`export_dashboard/2`).
- [`Lotus.AI`](../lib/lotus/ai.ex) — Public AI surface: `generate_query/1`, `generate_query_with_context/1`, `explain_query/1`, `suggest_optimizations/1`, `enabled?/0`, `supports?/2`, `unsupported_reason/2`, `model/0`.
- [`Lotus.AI.QueryGenerator`](../lib/lotus/ai/query_generator.ex), [`QueryExplainer`](../lib/lotus/ai/query_explainer.ex), [`QueryOptimizer`](../lib/lotus/ai/query_optimizer.ex) — Request orchestration for each AI capability.
- [`Lotus.AI.Conversation`](../lib/lotus/ai/conversation.ex) — Multi-turn conversation state used for iterative refinement.
- [`Lotus.AI.Actions`](../lib/lotus/ai/actions.ex) and `lib/lotus/ai/actions/` — Tool definitions the LLM can call (schema listing, column value sampling, statement validation/execution).
- `Lotus.AI.Prompts.*` (`lib/lotus/ai/prompts/`) — Prompt templates for query generation, explanation, optimization, and variable inference.
- [`Lotus.AI.SchemaOptimizer`](../lib/lotus/ai/schema_optimizer.ex) — Trims schema context before it is sent to the LLM.

The AI layer is adapter-driven: each adapter's `ai_context/1` supplies its own
language identifier, example query, syntax notes, and error patterns. Only
adapters listed in `:trusted_source_adapters` have their free-form text passed
through to the prompt unchanged; for everything else only `:language` survives.

### Query Execution Pipeline

When you call `Lotus.run_query(query, opts)` the request flows through roughly the following stages. `Lotus.run_statement/3` skips the variable and storage stages but shares the rest.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.run_query / Lotus.run_statement                                │
│  • Merge variable defaults + opts[:vars]                             │
│  • Storage.Query.compile/2 → {:ok, %Statement{}}                     │
│    (per-variable dispatch to Adapter.substitute_variable/5)          │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Source.resolve!/2                                              │
│  • Configured resolver → %Lotus.Source.Adapter{}                     │
│  • Unknown name → raises; it never falls back to the default         │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Statement shaping (per-adapter, %Statement{} in / %Statement{} out)  │
│  • apply_filters/3 (Lotus.Query.Filter)                              │
│  • apply_sorts/3   (Lotus.Query.Sort)                                │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Runner.before_query/3                                          │
│  • Middleware.run(:before_query, _) — may rewrite the statement      │
│  • Outside the cache, so it runs on a hit too, and before pagination │
│    so a plug is handed the query the caller wrote                    │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ apply_pagination/3 → statement.meta[:count_spec]                     │
│  • Built from the statement the plug returned, so the page and its   │
│    count describe the same rows                                      │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Cache.get_or_store/4                                           │
│  • Key: from the configured Lotus.Cache.KeyBuilder, over the body,   │
│    bound values and window of the statement that will execute        │
│  • Tags: ["query:<id>", "source:<name>", "scope:<digest>", ...]      │
│  • Hit  → the stored %{result:, relations:}, then :before_execute    │
│  • Miss → run the fetcher below                                      │
└─────────────────────────────────────────────────────────────────────┘
                               │ miss / :bypass / :refresh
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Runner.execute_statement(%Adapter{}, %Statement{}, opts)       │
│  1. Telemetry.query_start                                            │
│  2. Adapter.sanitize_query (single statement + deny list)            │
│  3. Adapter.needs_preflight? → Lotus.Preflight.authorize             │
│  4. Middleware.run(:before_execute, _) — carries the relations       │
│  5. Adapter.transaction (read-only) → Adapter.execute_query          │
│  6. Column policy enforcement (omit / mask / error)                  │
│  7. Telemetry.query_stop / query_exception                           │
│  → {:ok, %{result:, relations:}}, which is what the cache stores     │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Runner.after_query/4                                           │
│  • Middleware.run(:after_query, _) — on the result, hit or miss      │
│  • Outside the cache, so a plug that changes the result changes      │
│    what this caller gets, not what is stored                         │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                          Lotus.Result
```

A few notes on the pipeline:

- **Variable binding** happens inside `Lotus.Storage.Query.compile/2`, which also consults `Lotus.Storage.SchemaCache` for type-aware casting of user-supplied values. Substitution itself is adapter-owned: prepared-statement adapters push a placeholder into `statement.body` and the value into `statement.params`, while JSON/DSL adapters inline a properly escaped literal. **Those adapters are the injection boundary** — escape through the target language's own encoder, never by string concatenation.
- **Filters and sorts** are injected through the adapter, not concatenated naively — see `Lotus.Source.Adapters.Ecto.SQL.FilterInjector` and `SortInjector`. An adapter must declare the operators it handles via `supported_filter_operators/1`; anything else raises `Lotus.UnsupportedOperatorError`.
- **Pagination** has two strategies for `count: :exact`. An engine that returns the total as a side-effect of the main query puts it in `execute_query/4`'s `:total_count` key; everything else places a count spec in `statement.meta[:count_spec]` and Lotus core runs it. The inline count wins when both are present.
- **Caching** is optional. When no cache adapter is configured, `Lotus.Cache` is a pass-through and the fetcher always runs. The cache wraps the execution phase only, and stores the relations preflight found alongside the result, so all three query events fire on a hit — `:before_execute` gates on the stored relations. `Lotus.Runner.run_statement/3` composes the same phases with no cache between them. What a hit skips is sanitization, preflight and column visibility, all of which read `:scope`, which is in the key.
- **Preflight** is skipped when `needs_preflight?/2` returns false (the Ecto adapter keeps the `EXPLAIN` / `SHOW` / `PRAGMA` heuristic internally). The relations it discovers are stashed in `Lotus.Preflight.Relations`, from where the runner reads them once and carries them down the pipeline — to `:before_execute` middleware, and to column visibility policy lookup, without re-parsing the statement. An adapter that cannot enumerate resources returns `{:unrestricted, reason}`, which is blocked unless the operator opts in with `:allow_unrestricted_resources`.
- **Middleware runs first**, outside the cache and before pagination, sanitization and preflight, because a `:before_query` plug may rewrite the statement — row-level security and tenant predicates are the point of the hook. Sanitization and preflight then apply to whatever will actually execute. Halting from a `:before_query` plug yields `{:error, reason}` to the caller. A plug that needs the table list instead of the chance to rewrite registers `:before_execute`, which runs once preflight has named the relations.

### Schema Introspection Flow

Schema calls follow a simpler path but share the same adapter and middleware infrastructure:

```
Lotus.Schema.list_schemas / list_tables / describe_table / list_relations
  │
  ▼
Lotus.Source.resolve!/2         (→ %Adapter{})
  │
  ▼
Lotus.Cache.get_or_store         (optional, discovery_key/2)
  │
  ▼
Adapter dispatch → source-specific introspection
  │
  ▼
Lotus.Visibility filtering       (schema > table > column)
  │
  ▼
Middleware.run(:after_list_schemas | :after_list_tables | ...)
  │
  ▼
Middleware.run(:after_discover)
  │
  ▼
Telemetry.schema_introspection_stop
```

Column metadata discovered during `describe_table/3` is additionally cached in
`Lotus.Storage.SchemaCache`, which is what powers type-aware variable casting
when queries run.

Note the naming: `describe_table/3` returns **column definitions**;
`list_schemas/1` and `resolve_table_namespace/3` deal with **namespaces**. The
v1 rename exists to keep those two meanings of "schema" apart — please preserve
it when adding callbacks.

### Adapter Patterns

Lotus has four pluggable extension points. Each is a behaviour plus a default implementation, so you can swap any of them without forking the library.

| Extension point            | Behaviour                                     | Config key              | Default                                  |
|----------------------------|-----------------------------------------------|-------------------------|------------------------------------------|
| Data source adapter        | `Lotus.Source.Adapter`                        | `:source_adapters`      | `Lotus.Source.Adapters.{Postgres,MySQL,SQLite3,Ecto}` |
| SQL dialect (Ecto only)    | `Lotus.Source.Adapters.Ecto.Dialect`          | —                       | `Lotus.Source.Adapters.Ecto.Dialects.*`  |
| Source resolver            | `Lotus.Source.Resolver`                       | `:source_resolver`      | `Lotus.Source.Resolvers.Static`          |
| Visibility resolver        | `Lotus.Visibility.Resolver`                   | `:visibility_resolver`  | `Lotus.Visibility.Resolvers.Static`      |
| Cache adapter              | `Lotus.Cache.Adapter`                         | `cache: %{adapter: _}`  | `Lotus.Cache.ETS` (or `Lotus.Cache.Cachex`) |
| Cache key builder          | `Lotus.Cache.KeyBuilder`                      | `cache: %{key_builder: _}` | `Lotus.Cache.KeyBuilder.Default`      |

Design notes for adapter authors:

- **Source adapters** carry state in the `%Adapter{}` struct itself (e.g. an Ecto repo module) so the runner never closes over the raw connection. Every introspection callback returns `{:ok, _} | {:error, _}`.
- **A SQL engine on Ecto** should implement a `Dialect` and `use Lotus.Source.Adapters.Ecto, dialect: MyDialect` rather than implementing the universal behaviour from scratch.
- **A non-SQL engine** implements `Lotus.Source.Adapter` directly and carries its native payload (JSON map, DSL AST) in `statement.body`. Do not serialize it to a string to satisfy an old SQL-shaped signature.
- **Source resolvers** let you replace the static `data_sources` map with a dynamic registry (database-backed tenants, feature-flagged sources, etc.).
- **Visibility resolvers** let you compute schema/table/column policies from external sources instead of config — useful when rules live in a multi-tenant database.
- **Cache adapters** implement `Lotus.Cache.Adapter`. ETS is the zero-dependency option; Cachex is recommended when you need richer stats.

See the [source adapters guide](source-adapters.md) for the full callback walkthrough.

### Design Principles

A few opinions run through the codebase; preserving them when you contribute will make review much easier.

1. **Read-only by default, with defense in depth.** Destructive statements are blocked by (a) the adapter's sanitizer and deny list, (b) preflight authorization, and (c) a database-level read-only transaction. Each layer exists because the previous one can be bypassed in some edge case. Opting out (`read_only: false`) is a deliberate, explicit flag.
2. **Pluggable, not hardcoded.** Sources, dialects, resolvers, caches, and visibility all go through behaviours. Avoid pattern-matching on concrete modules inside the query pipeline — dispatch through the adapter.
3. **Nothing in the pipeline assumes SQL.** The pipeline carries a `%Lotus.Query.Statement{}` whose `:body` is an adapter-opaque term. New core code must not inspect, parse or concatenate it.
4. **No silent degradation.** If an adapter cannot express a filter operator, enforce visibility, or produce a row total, it says so and Lotus surfaces an error or an honest `nil` — it never quietly returns a different answer than was asked for.
5. **Visibility is schema, table, and column.** Schema visibility is checked before table visibility, and column policies (omit/mask/error) run inside the runner after the result comes back. Any new introspection path must respect all three.
6. **Session state is scoped and explicit.** Per-request state like statement timeouts and search paths is set by the adapter at the start of a transaction; there is no hidden global state. `Lotus.Preflight.Relations` is the one place we use the process dictionary, and it's scrubbed per call.
7. **Type-aware caching.** Query results and schema metadata are cached separately, with keys from a swappable `KeyBuilder` and tags for targeted invalidation. Column metadata lives in `Lotus.Storage.SchemaCache` so value casting doesn't require re-introspection.
8. **Observability is first-class.** Every meaningful operation emits `[:lotus, ...]` telemetry events. New features should do the same (look at `Lotus.Telemetry` for helpers).
9. **Middleware is the extension seam for cross-cutting concerns.** Auditing, access control, and per-tenant overrides belong in middleware plugs — not in the runner itself.

### Where to Look Next

- New to the pipeline? Start in [`Lotus`](../lib/lotus.ex) (`run_query/2`) and follow the calls into [`Lotus.Runner`](../lib/lotus/runner.ex).
- Working on a new SQL database? See the [source adapters guide](source-adapters.md) and mimic [`Lotus.Source.Adapters.Ecto.Dialects.Postgres`](../lib/lotus/source/adapters/ecto/dialects/postgres.ex).
- Working on a non-SQL engine? Read [`Lotus.Source.Adapter`](../lib/lotus/source/adapter.ex) end to end, then look at the in-memory test adapter in `test/support/in_memory_adapter.ex` and its end-to-end test in `test/integration/non_sql/`.
- Working on caching? [`Lotus.Cache`](../lib/lotus/cache.ex) and [`Lotus.Cache.ETS`](../lib/lotus/cache/ets.ex) are the smallest self-contained example.
- Working on visibility or auditing? Start in [`Lotus.Visibility`](../lib/lotus/visibility.ex) and [`Lotus.Middleware`](../lib/lotus/middleware.ex).
- Working on AI features? Begin with [`Lotus.AI`](../lib/lotus/ai.ex) and follow the calls into `lib/lotus/ai/`.

## Development Workflow

### Branches and Commits

Lotus uses [Conventional Commits](https://www.conventionalcommits.org/) for
commit messages and PR titles, and a matching branch convention.

**Branch names** — `<type>/<short-desc>`:

```bash
git checkout -b fix/preload-dashboards
git checkout -b feat/clickhouse-dialect
```

**Commit messages and PR titles** — `<type>(<scope>): <description>`:

```
feat(dashboards): add preload option to list_dashboard_cards
fix(preflight): honour needs_preflight? for SHOW statements
docs(contributing): document the docker compose ports
```

- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`
- Scope is optional
- Description: imperative, lowercase, no trailing period

### Making Changes

1. **Create a branch** following the convention above.

2. **Make your changes**
   - Follow the existing code style
   - Add tests for new functionality
   - Update the relevant guide under `guides/`

3. **Test your changes**
   ```bash
   # Run all tests
   mix test

   # Run a specific test file
   mix test test/lotus/storage_test.exs

   # Run with coverage
   mix test --cover
   ```

4. **Run the checks CI runs**
   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix credo --strict
   mix dialyzer
   ```

   `mix lint` is a shortcut for `mix format` followed by `mix dialyzer`.

5. **Commit and push, then open a pull request.**

### Continuous Integration

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`.
It builds a matrix of:

| Elixir | Erlang/OTP | PostgreSQL |
|--------|------------|------------|
| 1.18 | 27.3.2 | 15.8-alpine |
| 1.19 | 27.3.2 | 15.8-alpine |
| 1.20 | 29.0.2 | 15.8-alpine |

MySQL 8.0 runs as a service in every matrix entry. Each job runs, in order:
`mix deps.get`, `mix format --check-formatted`, `mix deps.compile`,
`mix compile --warnings-as-errors`, `mix credo --strict`, `mix test.setup`,
`mix test`, and `mix dialyzer`. A warning is a failure, so compile cleanly
before you push.

### Code Style Guidelines

#### Elixir Style

- Use `mix format` to ensure consistent formatting
- `mix credo --strict` must pass
- Use descriptive variable and function names

#### Documentation

- All public functions must have `@doc` strings
- Use `@spec` for type specifications — Dialyzer runs in CI with `:underspecs` enabled
- Include examples in documentation when helpful

```elixir
@doc """
Creates a new query with the given attributes.

## Parameters

  * `attrs` - A map containing query attributes

## Returns

  * `{:ok, query}` - Successfully created query
  * `{:error, changeset}` - Validation or database errors

## Examples

    iex> Lotus.create_query(%{name: "User Count", statement: "SELECT COUNT(*) FROM users"})
    {:ok, %Lotus.Storage.Query{}}

"""
@spec create_query(map()) :: {:ok, Query.t()} | {:error, Ecto.Changeset.t()}
def create_query(attrs) do
  # Implementation
end
```

#### Testing

Tests use ExUnit with [Mimic](https://hex.pm/packages/mimic) for mocking.
Shared cases live in `test/support/`: `Lotus.Case`, `Lotus.CacheCase`, and
`Lotus.AICase`, plus fixtures and an in-memory non-SQL adapter.

- Write tests for all new functionality
- Use descriptive test names
- Group related tests with `describe` blocks
- Include both happy path and error case tests

```elixir
describe "create_query/1" do
  test "creates query with valid attributes" do
    attrs = %{name: "Test Query", statement: "SELECT 1"}

    assert {:ok, query} = Lotus.create_query(attrs)
    assert query.name == "Test Query"
  end

  test "returns error with invalid attributes" do
    attrs = %{name: "", statement: "SELECT 1"}

    assert {:error, changeset} = Lotus.create_query(attrs)
    assert "can't be blank" in errors_on(changeset).name
  end
end
```

## Types of Contributions

### Bug Reports

When reporting bugs, please include:

- **Environment**: Elixir version, OTP version, Lotus version, data source type and version
- **Steps to reproduce**: Clear, step-by-step instructions
- **Expected behavior**: What you expected to happen
- **Actual behavior**: What actually happened
- **Error messages**: Full error messages and stack traces
- **Code samples**: Minimal code that reproduces the issue

### Feature Requests

For new features, please include:

- **Problem description**: What problem does this solve?
- **Proposed solution**: How would you like it to work?
- **Alternatives considered**: What other approaches did you consider?
- **Examples**: Show how the feature would be used

Frame the problem first. A well-described problem gets a better solution than a
prescribed implementation.

### Code Contributions

We welcome contributions of all sizes! Here are some areas where help is especially appreciated:

#### Good First Issues

- Documentation improvements
- Additional test coverage
- Small bug fixes
- Code formatting and style improvements

#### Medium Complexity

- New configuration options
- Performance optimizations
- Additional statement validation features
- Enhanced error messages

#### Advanced Features

- New source adapters, in-tree or as a companion package
- Additional cache backends (Redis, distributed caching)
- Cache statistics and richer telemetry
- Query performance monitoring and metrics
- Visibility rule enhancements

## Pull Request Process

### Before Submitting

1. **Check existing issues**: Make sure your change isn't already being worked on
2. **Discuss large changes**: Open an issue to discuss major features or breaking changes
3. **Update documentation**: Include relevant guide updates
4. **Add tests**: Ensure your changes are well-tested
5. **Follow conventions**: Conventional Commits, and match the existing code style

### Pull Request Template

When creating a pull request, please include:

```markdown
## Description
Brief description of the changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Refactoring

## Testing
- [ ] Tests pass locally
- [ ] New tests added for functionality
- [ ] Documentation updated

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Corresponding documentation updated
```

### Review Process

1. **Automated checks**: CI will run tests, formatting, Credo, and Dialyzer
2. **Code review**: Maintainers will review your changes
3. **Feedback**: Address any requested changes
4. **Approval**: Once approved, changes will be merged

## Development Guidelines

### Database Changes

Lotus migrations are versioned per database under `lib/lotus/migrations/`. The
PostgreSQL chain is currently at V5 (`lib/lotus/migrations/postgres/v1.ex`
through `v5.ex`); MySQL and SQLite have their own modules.

When making changes that affect the database:

1. **Add a new version module** rather than editing an existing one — installs in the wild have already run the old ones.
2. **Test migrations both ways**: ensure `up` and `down` work on PostgreSQL, MySQL, and SQLite.
3. **Note manual steps**: MySQL and SQLite users have historically needed manual DDL for some changes (see the v1.0.0 `CHANGELOG.md` entry). Say so explicitly in the changelog.
4. **Test multi-database**: verify changes work across all three built-in adapters.

### Testing Multi-Database Features

Integration tests carry `@moduletag :postgres`, `:mysql`, or `:sqlite`:

```bash
# Only the SQLite-tagged integration tests
mix test --only sqlite

# Everything except the MySQL-tagged tests (useful without a MySQL container)
mix test --exclude mysql

# A whole area
mix test test/lotus/visibility_test.exs
mix test test/lotus/data_source_test.exs
mix test test/integration/non_sql
```

Unit tests are untagged and always run. `test/test_helper.exs` recreates all
three databases and runs their support migrations before the suite starts, so
the containers must be up.

### Caching Features

When working on caching-related features:

```bash
mix test test/lotus/cache_test.exs
mix test test/lotus/cache_telemetry_test.exs
mix test test/integration/caching_test.exs
mix test test/lotus/cache
```

**Contributing a new cache backend:**

1. **Implement the behaviour**: create a module with `@behaviour Lotus.Cache.Adapter`
2. **Required callbacks**: `get/1`, `put/4`, `delete/1`, `get_or_store/4`, `invalidate_tags/1`, `touch/2`, `spec_config/0`
3. **Add tests**: follow the ETS adapter's test module
4. **Document it**: update the [caching guide](caching.md)
5. **Keep dependencies optional**: mark the driver `optional: true` in `mix.exs`

### API Changes

v1.0 removed the entire pre-v1 compatibility layer, and the project intends to
keep the v1 surface stable. For changes to the public API:

1. **Prefer additive changes**: new optional callbacks with defaults, new options with defaults
2. **Breaking changes need a major version** and an entry in the upgrade guide
3. **Document thoroughly**: update `CHANGELOG.md` and every affected guide
4. **Examples**: update examples in the guides so every code block still runs

### Performance Considerations

- **Benchmark changes**: use `:timer.tc/1` or benchmarking tools for performance-critical changes
- **Memory usage**: be mindful of memory allocation in hot paths
- **Database queries**: optimize query patterns and avoid N+1 queries (`Lotus.Dashboards.run_dashboard/2` preloads all card mappings in one go for exactly this reason)

## Release Process

### Versioning

Lotus follows [Semantic Versioning](https://semver.org/):

- **Major (2.0.0)**: Breaking changes
- **Minor (1.1.0)**: New features, backward compatible
- **Patch (1.0.1)**: Bug fixes, backward compatible

### Changelog

All notable changes are documented in `CHANGELOG.md`:

- **Added**: New features
- **Changed**: Changes in existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security improvements

## Community Guidelines

### Code of Conduct

We are committed to providing a welcoming and inspiring community for all. Please:

- **Be respectful**: Treat everyone with respect and kindness
- **Be inclusive**: Welcome newcomers and help them get started
- **Be constructive**: Provide helpful feedback and suggestions
- **Be patient**: Remember that everyone has different experience levels

### Communication

- **GitHub Issues**: For bug reports, feature requests, and discussions
- **Pull Requests**: For code contributions and reviews
- **Discussions**: For general questions and community interaction

### Getting Help

If you need help:

1. **Check the documentation**: start with the guides and the API documentation on [HexDocs](https://hexdocs.pm/lotus)
2. **Search existing issues**: your question might already be answered
3. **Ask in discussions**: use GitHub Discussions for general questions
4. **Open an issue**: for specific bugs or feature requests

## Recognition

Contributors are recognized in release notes and in the GitHub contributors
list, and significant documentation contributions are attributed in the guides
themselves.

## License

By contributing to Lotus, you agree that your contributions will be licensed under the same license as the project (MIT License).

---

Thank you for contributing to Lotus! Your help makes this project better for everyone.
