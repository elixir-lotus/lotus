# Lotus

![Lotus](https://raw.githubusercontent.com/elixir-lotus/lotus/main/media/banner.png)

<p>
  <a href="https://hex.pm/packages/lotus">
    <img alt="Hex Version" src="https://img.shields.io/hexpm/v/lotus.svg">
  </a>
  <a href="https://hexdocs.pm/lotus">
    <img src="https://img.shields.io/badge/docs-hexdocs-blue" alt="HexDocs">
  </a>
  <a href="https://github.com/elixir-lotus/lotus/actions">
    <img alt="CI Status" src="https://github.com/elixir-lotus/lotus/workflows/ci/badge.svg">
  </a>
</p>

**The embeddable BI engine for Elixir apps — query editor, dashboards, visualizations, and AI-powered query generation that mount directly in your Phoenix app. SQL and non-SQL data sources behind one pluggable adapter contract. No Metabase. No Redash. No extra infrastructure.**

[Try the live demo](https://lotus.typhoon.works/)

<!-- TODO: Replace with a 30-second demo GIF showing: mount in router → open browser → write SQL → see chart → save to dashboard -->

## Why Lotus?

Every app eventually needs analytics, reporting, or an internal SQL tool. The usual options — Metabase, Redash, Grafana — mean another service to deploy, another auth system to sync, another thing to keep running.

Lotus takes a different approach: it mounts inside your Phoenix app. Add the dependency, run a migration, add one line to your router, and you have a full BI interface — query editor, charts, dashboards — running on your existing infrastructure. Read-only by design, production-safe from day one.

And it is not limited to SQL. Every data source is wrapped behind a uniform `Lotus.Source.Adapter` contract, so a Postgres repo, a ClickHouse HTTP endpoint, and an Elasticsearch cluster all run through the same pipeline, the same visibility rules, the same cache, and the same AI assistant.

## See It in Action

[Try the live demo](https://lotus.typhoon.works/) — a full Lotus Web instance with sample data.

**What you get out of the box:**
- Ask your database questions in plain English — AI-powered query generation with multi-turn conversations, query explanations, and optimization suggestions (bring your own OpenAI, Anthropic, or Gemini key)
- Web-based query editor with syntax highlighting and autocomplete
- Interactive schema explorer for browsing tables and columns
- 5 chart types (bar, line, area, scatter, pie) saved per query
- Dashboards with grid layouts, auto-refresh, and public sharing

Lotus Web is the companion UI package — see [lotus_web](https://github.com/elixir-lotus/lotus_web).

## Quick Start

Get a fully working BI dashboard in your Phoenix app in under 5 minutes.

### 1. Add dependencies

```elixir
# mix.exs
def deps do
  [
    {:lotus, "~> 1.0"},
    {:lotus_web, "~> 1.0"}
  ]
end
```

### 2. Configure Lotus

```elixir
# config/config.exs
config :lotus,
  storage_repo: MyApp.Repo,
  default_source: "main",
  data_sources: %{
    "main" => MyApp.Repo
  }
```

### 3. Run the migration

```bash
mix ecto.gen.migration create_lotus_tables
```

```elixir
defmodule MyApp.Repo.Migrations.CreateLotusTables do
  use Ecto.Migration

  def up, do: Lotus.Migrations.up()
  def down, do: Lotus.Migrations.down()
end
```

```bash
mix ecto.migrate
```

### 4. Mount in your router

```elixir
# lib/my_app_web/router.ex
import Lotus.Web.Router

scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  lotus_dashboard "/lotus"
end
```

### 5. Visit `/lotus` in your browser

That's it. You have a full BI dashboard running inside your Phoenix app.

For the complete setup guide (caching, multiple databases, visibility controls), see the [installation guide](guides/installation.md).

## Features

- **Query editor** with syntax highlighting, autocomplete, and real-time execution
- **Query management** — save, organize, and reuse queries with descriptive names
- **Smart variables** — parameterize queries with `{{variable}}` syntax, configurable input widgets, and query-backed dropdown options. Each adapter owns its own substitution, so prepared-statement engines bind parameters while JSON/DSL engines inline properly escaped literals
- **Visualizations** — 5 chart types (bar, line, area, scatter, pie) with renderer-agnostic config DSL
- **Dashboards** — combine queries into interactive views with 12-column grid layouts, filters mapped onto query variables, auto-refresh, and public sharing via secure tokens
- **Pluggable data sources** — every source is wrapped in a uniform `Lotus.Source.Adapter` behaviour, so the execution pipeline is decoupled from Ecto and SQL. First-party adapters cover PostgreSQL, MySQL, and SQLite; external packages add [ClickHouse](https://github.com/elixir-lotus/lotus_clickhouse) and [Elasticsearch](https://github.com/elixir-lotus/lotus_elasticsearch). Custom adapters target anything else, and custom resolvers can load sources dynamically from a database or external service. See the [source adapters guide](guides/source-adapters.md)
- **Result caching** — TTL-based caching with ETS or Cachex backends, cache profiles, a pluggable `Lotus.Cache.KeyBuilder`, and tag- and scope-based invalidation
- **Exports** — CSV, JSON, and JSONL, with streaming CSV for large result sets and a ZIP export of a whole dashboard
- **Result filters** — apply column-level filters on query results via `Lotus.Query.Filter`; multiple filters stack with AND, and each adapter declares which operators it supports
- **Result sorting** — apply column-level sorting on query results via `Lotus.Query.Sort`, injected by the adapter rather than concatenated
- **Windowed pagination** — `window: [limit: _, offset: _, count: :exact | :none]` on any query, with the exact total supplied either inline by the engine or by a separate count query
- **Schema explorer** — browse namespaces, tables, columns, and statistics interactively
- **AI query generation** — ask your database questions in plain English; schema-aware, multi-turn conversations using OpenAI, Anthropic, Gemini, or any other ReqLLM provider (BYOK)
- **AI query explanation** — get plain-language explanations of what a query does, including selected fragments; understands Lotus `{{variable}}` and `[[optional]]` syntax
- **AI query optimization** — get actionable optimization suggestions (indexes, rewrites, schema changes) powered by query-plan analysis
- **Adapter-driven AI** — each adapter describes its own query language, example query, syntax notes, and error patterns through `ai_context/1`, so the assistant speaks the engine's dialect instead of assuming SQL. Free-form adapter text only reaches the prompt for adapters you list in `:trusted_source_adapters`
- **Three-level visibility** — schema, table, and column rules, with schema taking precedence over table and per-column `:omit` / `{:mask, _}` / `:error` policies applied to result rows
- **Middleware** — a plug-style pipeline with `:before_query`, `:before_execute`, `:after_query`, and `:after_list_*` hooks for auditing, access control, per-tenant statement rewriting, and authorizing on the tables a statement provably touches
- **Telemetry** — `[:lotus, ...]` events for query execution, schema introspection, and cache hits and misses
- **Read-only by default** — all queries run in read-only transactions with automatic timeout controls and session state management (opt out per-query with `read_only: false`)

## Production Ready

Lotus is built for production use from the ground up:

- **Read-only execution** — all queries run inside read-only transactions by default. No accidental writes. Pass `read_only: false` to enable writes.
- **Session state management** — connection pool state is automatically preserved and restored after each query, preventing pool pollution.
- **Automatic type casting** — query variables are cast to match column types (UUIDs, dates, numbers, booleans, enums) using schema metadata, with graceful fallbacks.
- **Timeout controls** — configurable per-query timeouts with sensible defaults.
- **Defense-in-depth** — preflight authorization, schema/table/column visibility controls, and built-in system table protection.
- **No silent degradation** — an adapter declares which filter operators it handles and whether it can enforce visibility. A filter it cannot express raises `Lotus.UnsupportedOperatorError`, and a source that cannot report which resources a statement touches is blocked until you opt in with `:allow_unrestricted_resources`.
- **Language-aware saved queries** — a saved query records the `family:dialect` it was written for (`sql:postgres`, `json:elasticsearch`). Repointing it at a source that speaks a different language returns an error instead of handing the statement to an engine that cannot parse it.

## Using Lotus as a Library

Lotus works great as a standalone library without the web UI. Use it to run queries, manage saved queries, and build analytics features programmatically.

### Configuration

```elixir
config :lotus,
  storage_repo: MyApp.Repo,
  default_source: "main",
  data_sources: %{
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  }

# Optional: Configure caching
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp"
  }
```

A data source value is either an Ecto repo module (handled by the built-in Ecto
adapter) or a config map naming a custom adapter:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,
  default_source: "main",
  data_sources: %{
    "main" => MyApp.Repo,
    "events" => %{adapter: MyApp.ElasticsearchAdapter, url: "http://localhost:9200"}
  },
  source_adapters: [MyApp.ElasticsearchAdapter]
```

### Creating and Running Queries

```elixir
# Create and save a query
{:ok, query} = Lotus.create_query(%{
  name: "Active Users",
  statement: "SELECT * FROM users WHERE active = true"
})

# Execute a saved query
{:ok, results} = Lotus.run_query(query)

# Execute a statement directly (read-only)
{:ok, results} = Lotus.run_statement("SELECT * FROM products WHERE price > $1", [100])

# Execute against a specific data source
{:ok, results} = Lotus.run_statement("SELECT COUNT(*) FROM events", [], repo: "analytics")

# Page through results with an exact total
{:ok, results} = Lotus.run_statement("SELECT * FROM orders", [],
  window: [limit: 50, offset: 100, count: :exact]
)
results.meta.total_count
```

### Exploring the Schema

```elixir
Lotus.list_data_source_names()
# => ["main", "analytics"]

{:ok, tables}  = Lotus.list_tables("main")
{:ok, columns} = Lotus.describe_table("main", "users")
{:ok, stats}   = Lotus.get_table_stats("main", "users")
```

### AI Query Generation

Ask your database questions in plain English. The AI assistant discovers your schema, respects visibility rules, and generates an accurate, schema-qualified statement in the language the source actually speaks — the adapter supplies its own example query, syntax notes, and error patterns. Supports multi-turn conversations for iterative refinement — no other embeddable BI tool does this.

```elixir
{:ok, result} = Lotus.AI.generate_query(
  prompt: "Show all customers with unpaid invoices",
  data_source: "main"
)

result.statement
#=> "SELECT c.id, c.name FROM reporting.customers c ..."

result.model
#=> "openai:gpt-4o"
```

Get a plain-language explanation of any query (or a selected fragment):

```elixir
{:ok, result} = Lotus.AI.explain_query(
  statement: "SELECT d.name, COUNT(o.id) FROM departments d LEFT JOIN orders o ...",
  data_source: "main"
)

result.explanation
#=> "This query shows departments ranked by total order count..."

# Explain just a highlighted fragment
{:ok, result} = Lotus.AI.explain_query(
  statement: "SELECT d.name FROM departments d LEFT JOIN employees e ON e.department_id = d.id",
  fragment: "LEFT JOIN employees e ON e.department_id = d.id",
  data_source: "main"
)
```

Get optimization suggestions for existing queries. `suggest_optimizations/1`
takes a `%Lotus.Query.Statement{}` so it works for non-SQL engines too:

```elixir
statement = Lotus.Query.Statement.new("SELECT * FROM orders WHERE created_at > $1", ["2024-01-01"])

{:ok, result} = Lotus.AI.suggest_optimizations(
  statement: statement,
  data_source: "main"
)

result.suggestions
#=> [%{"type" => "index", "impact" => "high",
#=>    "title" => "Add index on orders.created_at", ...}]
```

Bring your own API key for OpenAI, Anthropic, Gemini, or any other provider
ReqLLM supports. A source whose adapter opts out of AI returns
`{:error, :ai_not_supported_for_source}`. See the
[AI query generation guide](guides/ai_query_generation.md) for setup,
multi-turn conversation support, and query optimization.

## Configuration

See the [configuration guide](guides/configuration.md) for all options including:

- Data source setup (single source, multi-database, and non-Ecto adapters)
- Registering custom adapters (`:source_adapters`) and trusting their AI context (`:trusted_source_adapters`)
- Custom source and visibility resolvers (`:source_resolver`, `:visibility_resolver`)
- Schema, table, and column visibility controls
- Cache backends, TTL profiles, and key builders
- Middleware pipelines
- AI configuration
- Query execution options (timeouts, search paths, read-only)

## Upgrading

Upgrading from Lotus v0.x? See the [upgrading to v1.0 guide](guides/upgrading-to-v1.md)
for the full list of config renames, DB column renames, middleware/telemetry
payload changes, and adapter-contract updates — plus a step-by-step
upgrade checklist.

## Data Sources

| Source | Package | Query language |
|---|---|---|
| **PostgreSQL** | built in (`Lotus.Source.Adapters.Postgres`) | `sql:postgres` |
| **MySQL** | built in (`Lotus.Source.Adapters.MySQL`) | `sql:mysql` |
| **SQLite** | built in (`Lotus.Source.Adapters.SQLite3`) | `sql:sqlite` |
| **Any other Ecto repo** | built in (`Lotus.Source.Adapters.Ecto` fallback) | `sql` |
| **ClickHouse** | [lotus_clickhouse](https://github.com/elixir-lotus/lotus_clickhouse) | `sql:clickhouse` |
| **Elasticsearch** | [lotus_elasticsearch](https://github.com/elixir-lotus/lotus_elasticsearch) | `json:elasticsearch` |
| **Anything else** | your own `Lotus.Source.Adapter` | whatever you declare |

Ecto-backed engines only need a dialect module
(`use Lotus.Source.Adapters.Ecto, dialect: MyDialect`). Non-SQL engines
implement `Lotus.Source.Adapter` directly and carry a native payload — a JSON
map, a DSL AST — through the pipeline without ever serializing it to a string.
See the [source adapters guide](guides/source-adapters.md).

## How Lotus Compares

| | Lotus | Metabase | Redash | Blazer (Rails) | Livebook |
|---|---|---|---|---|---|
| **Deployment** | Mounts in your app | Separate service | Separate service | Mounts in your app | Separate service |
| **Extra infra** | None | Java + DB | Python + Redis + DB | None | None |
| **Auth** | Uses your app's auth | Separate auth system | Separate auth system | Uses your app's auth | Token-based |
| **Language** | Elixir | Java/Clojure | Python | Ruby | Elixir |
| **Query editor** | Yes | Yes | Yes | Yes | Yes (in code cells) |
| **Non-SQL sources** | Yes (pluggable adapters) | Yes | Yes | No | Yes (any Elixir client) |
| **Dashboards** | Yes | Yes | Yes | No | No |
| **Charts** | 5 types | Many | Many | 3 types | Via libraries |
| **AI query gen** | Yes (BYOK) | No | No | No | No |
| **Read-only** | By design | Configurable | Configurable | Configurable | No |
| **Cost** | Free | Free/Paid | Free | Free | Free |

## Development Setup

### Prerequisites
- Elixir 1.18+ / OTP 27+
- Docker (the repo ships a `docker-compose.yml` with PostgreSQL 15 on port `2345` and MySQL 8.0 on port `3307`)
- SQLite 3

### Setup

```bash
git clone https://github.com/elixir-lotus/lotus.git
cd lotus
mix deps.get

# Start PostgreSQL and MySQL
docker compose up -d

mix ecto.setup
```

### Running tests

```bash
mix test.setup   # drop, create, and migrate the test databases
mix test
```

See the [contribution guide](guides/contributing.md) for the full workflow.

## Contributing

See the [contribution guide](guides/contributing.md) for details on how to contribute to Lotus.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
