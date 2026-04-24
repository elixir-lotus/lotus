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

**The embeddable BI engine for Elixir apps — SQL editor, dashboards, visualizations, and AI-powered query generation that mount directly in your Phoenix app. No Metabase. No Redash. No extra infrastructure.**

[Try the live demo](https://lotus.typhoon.works/)

<!-- TODO: Replace with a 30-second demo GIF showing: mount in router → open browser → write SQL → see chart → save to dashboard -->

## Why Lotus?

Every app eventually needs analytics, reporting, or an internal SQL tool. The usual options — Metabase, Redash, Grafana — mean another service to deploy, another auth system to sync, another thing to keep running.

Lotus takes a different approach: it mounts inside your Phoenix app. Add the dependency, run a migration, add one line to your router, and you have a full BI interface — SQL editor, charts, dashboards — running on your existing infrastructure. Read-only by design, production-safe from day one.

We're running Lotus in production at [Accomplish](https://accomplish.dev).

## See It in Action

[Try the live demo](https://lotus.typhoon.works/) — a full Lotus Web instance with sample data.

**What you get out of the box:**
- Ask your database questions in plain English — AI-powered query generation with multi-turn conversations, query explanations, and optimization suggestions (bring your own OpenAI, Anthropic, or Gemini key)
- Web-based SQL editor with syntax highlighting and autocomplete
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
    {:lotus, "~> 0.16.1"},
    {:lotus_web, "~> 0.14.0"}
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

- **SQL editor** with syntax highlighting, autocomplete, and real-time execution
- **Query management** — save, organize, and reuse queries with descriptive names
- **Smart variables** — parameterize queries with `{{variable}}` syntax, configurable input widgets, and SQL-backed dropdown options
- **Visualizations** — 5 chart types (bar, line, area, scatter, pie) with renderer-agnostic config DSL
- **Dashboards** — combine queries into interactive views with 12-column grid layouts, auto-refresh, and public sharing via secure tokens
- **Multi-database support** — PostgreSQL, MySQL, and SQLite with per-query repo selection
- **Result caching** — TTL-based caching with ETS backend, cache profiles, and tag-based invalidation
- **CSV export** — download query results with streaming support for large datasets
- **Result filters** — apply column-level filters on query results via `Lotus.Query.Filter`; multiple filters stack with AND and wrap the original query in a CTE for safe application
- **Result sorting** — apply column-level sorting on query results via `Lotus.Query.Sort`; sorts wrap the original query in a CTE so they work safely with any SQL complexity
- **Schema explorer** — browse tables, columns, and statistics interactively
- **AI query generation** — ask your database questions in plain English; schema-aware, multi-turn conversations using OpenAI, Anthropic, or Gemini (BYOK)
- **AI query explanation** — get plain-language explanations of what a query does, including selected fragments; understands Lotus `{{variable}}` and `[[optional]]` syntax
- **AI query optimization** — get actionable optimization suggestions (indexes, rewrites, schema changes) powered by EXPLAIN plan analysis
- **Read-only by default** — all queries run in read-only transactions with automatic timeout controls and session state management (opt out per-query with `read_only: false`)
- **Pluggable adapters** — data sources are wrapped in a uniform `Lotus.Source.Adapter` behaviour, decoupling the execution pipeline from Ecto. The default `Ecto` adapter works out of the box with your existing `data_sources` config. Custom adapters can target non-Ecto sources, and custom resolvers can load sources dynamically from a database or external service. See the [source adapters guide](guides/source-adapters.md).

## Production Ready

Lotus is built for production use from the ground up:

- **Read-only execution** — all queries run inside read-only transactions by default. No accidental writes. Pass `read_only: false` to enable writes.
- **Session state management** — connection pool state is automatically preserved and restored after each query, preventing pool pollution.
- **Automatic type casting** — query variables are cast to match column types (UUIDs, dates, numbers, booleans, enums) using schema metadata, with graceful fallbacks.
- **Timeout controls** — configurable per-query timeouts with sensible defaults.
- **Defense-in-depth** — preflight authorization, schema/table/column visibility controls, and built-in system table protection.

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

### Creating and Running Queries

```elixir
# Create and save a query
{:ok, query} = Lotus.create_query(%{
  name: "Active Users",
  statement: "SELECT * FROM users WHERE active = true"
})

# Execute a saved query
{:ok, results} = Lotus.run_query(query)

# Execute SQL directly (read-only)
{:ok, results} = Lotus.run_statement("SELECT * FROM products WHERE price > $1", [100])

# Execute against a specific data source
{:ok, results} = Lotus.run_statement("SELECT COUNT(*) FROM events", [], repo: "analytics")
```

### AI Query Generation

Ask your database questions in plain English. The AI assistant discovers your schema, respects visibility rules, and generates accurate, schema-qualified SQL. Supports multi-turn conversations for iterative refinement — no other embeddable BI tool does this.

```elixir
{:ok, result} = Lotus.AI.generate_query(
  prompt: "Show all customers with unpaid invoices",
  data_source: "my_repo"
)

result.sql
#=> "SELECT c.id, c.name FROM reporting.customers c ..."
```

Get a plain-language explanation of any query (or a selected fragment):

```elixir
{:ok, result} = Lotus.AI.explain_query(
  sql: "SELECT d.name, COUNT(o.id) FROM departments d LEFT JOIN orders o ...",
  data_source: "my_repo"
)

result.explanation
#=> "This query shows departments ranked by total order count..."

# Explain just a highlighted fragment
{:ok, result} = Lotus.AI.explain_query(
  sql: "SELECT d.name FROM departments d LEFT JOIN employees e ON e.department_id = d.id",
  fragment: "LEFT JOIN employees e ON e.department_id = d.id",
  data_source: "my_repo"
)
```

Get optimization suggestions for existing queries:

```elixir
{:ok, result} = Lotus.AI.suggest_optimizations(
  sql: "SELECT * FROM orders WHERE created_at > '2024-01-01'",
  data_source: "my_repo"
)

result.suggestions
#=> [%{"type" => "index", "impact" => "high",
#=>    "title" => "Add index on orders.created_at", ...}]
```

Bring your own OpenAI, Anthropic, or Gemini API key. See the [AI query generation guide](guides/ai_query_generation.md) for setup, multi-turn conversation support, and query optimization.

## Configuration

See the [configuration guide](guides/configuration.md) for all options including:

- Data repository setup (single and multi-database)
- Schema, table, and column visibility controls
- Cache backends and TTL profiles
- AI configuration
- Query execution options (timeouts, search paths)

## Upgrading

Upgrading from Lotus v0.x? See the [upgrading to v1.0 guide](guides/upgrading-to-v1.md)
for the full list of config renames, DB column renames, middleware/telemetry
payload changes, and adapter-contract updates — plus a step-by-step
upgrade checklist.

## How Lotus Compares

| | Lotus | Metabase | Redash | Blazer (Rails) | Livebook |
|---|---|---|---|---|---|
| **Deployment** | Mounts in your app | Separate service | Separate service | Mounts in your app | Separate service |
| **Extra infra** | None | Java + DB | Python + Redis + DB | None | None |
| **Auth** | Uses your app's auth | Separate auth system | Separate auth system | Uses your app's auth | Token-based |
| **Language** | Elixir | Java/Clojure | Python | Ruby | Elixir |
| **SQL editor** | Yes | Yes | Yes | Yes | Yes (in code cells) |
| **Dashboards** | Yes | Yes | Yes | No | No |
| **Charts** | 5 types | Many | Many | 3 types | Via libraries |
| **AI query gen** | Yes (BYOK) | No | No | No | No |
| **Read-only** | By design | Configurable | Configurable | Configurable | No |
| **Cost** | Free | Free/Paid | Free | Free | Free |

## Development Setup

### Prerequisites
- Elixir 1.17+ / OTP 25+
- PostgreSQL 14+, MySQL 8.0+, SQLite 3

### Setup

```bash
git clone https://github.com/elixir-lotus/lotus.git
cd lotus
mix deps.get

# Optional: Start MySQL with Docker Compose
docker compose up -d mysql

mix ecto.create && mix ecto.migrate
```

### Running tests

```bash
mix test
```

## Contributing

See the [contribution guide](guides/contributing.md) for details on how to contribute to Lotus.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
