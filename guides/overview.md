# Overview

Lotus is an embeddable BI engine for Elixir applications. It gives you safe,
read-only query execution against one or more data sources, persistent query
storage, dashboards, caching, visibility controls, and AI-assisted query
generation — all running inside your own application, with no extra service to
deploy.

## Why Lotus?

Modern applications often need to run analytical queries for reporting,
business intelligence, or data exploration. Executing arbitrary queries in
production comes with significant risks:

- **Security concerns**: Unrestricted access can lead to data breaches or accidental damage
- **Performance issues**: Poorly written queries can impact application performance
- **Organization challenges**: Ad-hoc queries scattered across codebases are hard to maintain
- **Reusability problems**: Useful queries get lost or duplicated

Lotus addresses these challenges by providing:

## Key Benefits

### 🔐 Safety First
- **Read-only execution**: Destructive operations are blocked by default (configurable with `read_only: false`)
- **Statement validation**: Every statement is sanitized by its adapter before execution — what counts as a write is the adapter's judgement, not a regex
- **Database-level guards**: PostgreSQL (`SET LOCAL transaction_read_only`), MySQL (`transaction_read_only`) and SQLite 3.8.0+ (`PRAGMA query_only`)
- **Session state preservation**: Original session settings are snapshotted and restored to prevent connection pool pollution
- **Preflight authorization**: Before a statement runs, Lotus resolves the tables it touches and checks them against your visibility rules
- **Three-level visibility**: Schema, table and column rules — including column masking (`:null`, `:sha256`, partial and fixed values). See [Visibility](visibility.md)
- **Timeout controls**: Configurable execution and statement timeouts prevent runaway queries

### 🔌 Pluggable Data Sources
- **Adapter contract**: Every source sits behind `Lotus.Source.Adapter`, so Lotus is not tied to SQL or to Ecto
- **First-party adapters**: PostgreSQL, MySQL and SQLite, built on Ecto (`Lotus.Source.Adapters.Postgres`, `.MySQL`, `.SQLite3`)
- **External adapters**: [`lotus_elasticsearch`](https://github.com/elixir-lotus/lotus_elasticsearch) and [`lotus_clickhouse`](https://github.com/elixir-lotus/lotus_clickhouse) ship as separate packages
- **Many sources at once**: Configure as many named data sources as you need and query each by name
- **Write your own**: See [Source Adapters](source-adapters.md)

### 📦 Organized Storage
- **Persistent queries**: Save queries with a name, description, typed variables, a data source and an optional search path
- **Version control friendly**: Queries live in your database, not scattered through code
- **Easy retrieval**: A simple API to find and execute saved queries

### ⚡ Developer Friendly
- **Simple API**: `Lotus.run_query/2` for saved queries, `Lotus.run_statement/3` for ad-hoc ones
- **Type safety**: Structured `Lotus.Result` values with consistent error handling
- **Result and schema caching**: Two independent caches with tag-based and scope-aware invalidation. See [Caching](caching.md)
- **Middleware**: Plug-style hooks on query execution and schema discovery. See [Middleware](middleware.md)
- **Telemetry**: `:telemetry` events for execution, caching and introspection. See [Telemetry](telemetry.md)
- **Schema introspection**: Discover schemas, tables, columns, relations and statistics

## Core Concepts

### Sources
A source is a named data store Lotus can query — `"main"`, `"warehouse"`. Each
one resolves to a `Lotus.Source.Adapter` struct that knows how to talk to the
underlying engine. `Lotus.Source.list_sources/0`, `get_source!/1` and
`default_source/0` are the entry points. Queries and introspection calls name a
source; an unnamed call uses the configured default.

### Queries
A saved query (`Lotus.Storage.Query`) holds a `statement`, a name and
description, embedded variable definitions, and the `data_source` it belongs to. Variables use
`{{variable_name}}` syntax with `[[optional blocks]]`, and each adapter decides
how a variable is substituted — a bind placeholder for SQL, an escaped literal
for JSON or DSL engines. See [Advanced Variables](advanced-variables.md).

A query may also record the `query_language` it was written for
(`sql:postgres`, `json:elasticsearch`). If the source it runs against speaks a
different language, Lotus refuses the run rather than handing the statement to
an engine that cannot parse it.

### Statements
Everything Lotus executes is a `%Lotus.Query.Statement{}`. Its `:body` is
adapter-opaque — SQL text for the Ecto-backed adapters, a JSON map or a DSL AST
for others — and `:params` carries the bound values (a list for positional
binds, a map for named ones). The same struct is what middleware and telemetry
receive.

### Execution
All execution goes through `Lotus.Runner`, which runs one pipeline for every
source: `:before_query` middleware (which may rewrite the statement), adapter
sanitization, preflight authorization, execution, column policy enforcement,
then `:after_query` middleware.

### Results
Results come back as a `Lotus.Result` struct with `columns`, `rows`,
`num_rows`, `duration_ms`, `command` and a `meta` map (connection id,
`total_count` for windowed queries, and so on).

### Visualizations
Visualizations are saved chart configurations attached to queries. Lotus stores
the config as an opaque map, giving consumers full flexibility over the
structure. Frontend applications like Lotus Web transform this config into
concrete chart specs (Vega-Lite, Recharts, etc.).

Before saving, `Lotus.validate_visualization_config/2` verifies that field
references in your config exist in the query results and that numeric
aggregations apply to numeric columns. This validation is optional and does not
enforce any particular config structure.

### Dashboards
Dashboards combine multiple queries into a single, interactive view. Each
dashboard contains cards arranged in a 12-column grid layout, with support for:

- **Query cards** — results from saved queries, with optional visualization overrides
- **Text/heading cards** — markdown text or section headings
- **Link cards** — quick navigation to related resources

Dashboard filters let users control data across multiple cards at once. A single
filter (a date range picker, say) can map to different query variables in each
card, so cards filter together without changing the underlying queries. See
[Dashboards](dashboards.md).

### AI
Lotus can generate, explain and optimize queries with an LLM. The prompts are
assembled from each adapter's own `ai_context/1` — its query language, example
query, syntax notes and error patterns — so the AI writes for the source it is
pointed at rather than assuming SQL. Free-form context from untrusted adapters
is stripped before it reaches the prompt. See
[AI Query Generation](ai_query_generation.md).

### Schema Introspection
`Lotus.list_schemas/2`, `list_tables/2`, `describe_table/3`,
`get_table_stats/3` and `list_relations/2` explore a source's structure. Every
result is filtered through your visibility rules and cached. See
[Schema Introspection](schema-introspection.md).

## Use Cases

Lotus is a good fit for:

- **Reporting dashboards**: Execute saved queries to generate reports
- **Data exploration**: Safely allow analysts to run custom queries
- **Business intelligence**: Organize and execute analytical queries
- **Metrics collection**: Store and run queries for application metrics
- **Data exports**: Generate CSV, JSON or JSONL extracts with `Lotus.Export`
- **Database administration**: Explore table structures and gather statistics
- **Multi-tenant applications**: Scope visibility, caching and middleware per tenant

## Lotus Web UI

For teams that need a visual interface,
[Lotus Web](https://github.com/elixir-lotus/lotus_web) provides a Phoenix
LiveView dashboard you can mount directly in your application. It's a
lightweight alternative to Metabase or Redash, offering:

- **Query editor** with syntax highlighting and autocomplete
- **AI assistant** for generating, explaining and optimizing queries
- **Interactive query management** and organization
- **Schema exploration** to browse tables and columns
- **Charts and dashboards** with grid layouts, auto-refresh and public sharing
- **Multi-source support** to query different data sources
- **Zero additional infrastructure** — runs inside your Phoenix app

## What's Next?

Continue with the [Installation Guide](installation.md) to set up Lotus in your
application, then [Getting Started](getting-started.md) for your first queries.
[Configuration](configuration.md) covers the full set of options.

Upgrading from v0.16.x? Start with [Upgrading to v1.0](upgrading-to-v1.md) —
v1 is a rewrite, not a drop-in replacement.
