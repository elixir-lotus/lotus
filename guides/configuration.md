# Configuration

This guide covers all configuration options available in Lotus and how to customize the library for your specific needs.

## Basic Configuration

Lotus configuration is typically placed in your `config/config.exs` file:

```elixir
config :lotus,
  ecto_repo: MyApp.Repo,        # Repository for Lotus query storage
  default_source: "main",       # Default data source for query execution
  data_sources: %{              # Data sources for executing queries
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  },
  cache: [                      # Optional caching configuration
    adapter: Lotus.Cache.ETS,   # Cache adapter (ETS for local, Cachex for distributed)
    namespace: "myapp_cache"    # Cache namespace (optional)
  ]
```

## Configuration Options

### Required Options

#### `ecto_repo` (required)

Specifies the Ecto repository where Lotus stores saved queries. This is where the `lotus_queries` table lives.

```elixir
config :lotus,
  ecto_repo: MyApp.Repo
```

**Type**: `module()`

#### `data_sources` (required)

A map of data sources where queries can be executed against actual data. This powerful feature allows Lotus to work with multiple databases simultaneously, supporting PostgreSQL, MySQL, and SQLite.

Keys are friendly names that you use when executing queries. Values are **either** Ecto repository modules (for SQL databases handled by the built-in Ecto adapter) **or** config maps (for non-Ecto adapters like Elasticsearch, ClickHouse-HTTP, or any custom `Lotus.Source.Adapter` implementation).

> **Deprecation note**: The old `:data_repos` config key is deprecated but still works. Please migrate to `:data_sources`.

```elixir
config :lotus,
  data_sources: %{
    # Ecto-backed sources (module values) — handled by the built-in Ecto adapter
    "main" => MyApp.Repo,           # Can be the same as ecto_repo
    "analytics" => MyApp.AnalyticsRepo,
    "reporting" => MyApp.ReportingRepo,
    "mysql_data" => MyApp.MySQLRepo,    # MySQL repository
    "sqlite_data" => MyApp.SqliteRepo,  # Mix database types

    # Non-Ecto sources (map values) — dispatched to a matching
    # source_adapters entry via its can_handle?/1 callback
    "search" => %{adapter: :elasticsearch, url: "http://localhost:9200"},
    "warehouse" => %{adapter: MyApp.ClickHouseAdapter, url: "http://ch:8123"}
  },
  source_adapters: [MyApp.ClickHouseAdapter]
```

**Type**: `%{String.t() => module() | map()}`

Map values are opaque to Lotus — the matching adapter's `wrap/2` callback interprets them. See the [source adapters guide](source-adapters.md) for details on registering custom adapters.

#### `default_source` (required when multiple data_sources)

When you have multiple data sources configured, you must specify which one to use by default when no explicit source is provided in query execution.

> **Deprecation note**: The old `:default_repo` config key is deprecated but still works. Please migrate to `:default_source`.

```elixir
config :lotus,
  default_source: "main",  # Must match a key in data_sources
  data_sources: %{
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  }
```

**Type**: `String.t()`
**Default**: Not required if only one data source is configured

**Behavior**:
- **Single source**: When only one data source is configured, it's automatically used as the default
- **Multiple sources**: You must configure `default_source` to specify which one to use when no source is explicitly provided
- **No sources**: Raises an error if no data sources are configured

**Usage Examples:**

```elixir
# Execute against a specific repository by name
Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: "analytics")

# Execute against a repository module directly
Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: MyApp.AnalyticsRepo)

# When no repo is specified, uses the configured default_source
Lotus.run_statement("SELECT COUNT(*) FROM users")  # Uses "main" from default_source config
```

**Data Source Management:**

```elixir
# List all configured data source names
source_names = Lotus.list_data_source_names()
# ["analytics", "main", "reporting", "sqlite_data"]

# Get all configured data sources
all_sources = Lotus.data_sources()
# %{"analytics" => MyApp.AnalyticsRepo, "main" => MyApp.Repo, ...}

# Get a specific data source by name (raises if not found)
source = Lotus.get_data_source!("analytics")
# MyApp.AnalyticsRepo
```

> **Note**: The `ecto_repo` can also be included in `data_sources` if you want to run queries against the same database where Lotus stores its data. This is common in single-database applications.

### Optional Features

#### `cache`

Configures result caching to improve query performance. When enabled, Lotus automatically caches query results and reuses them for identical queries.

```elixir
config :lotus,
  cache: [
    adapter: Lotus.Cache.ETS,         # Cache adapter (required)
    namespace: "myapp_cache",         # Cache namespace (optional)
    max_bytes: 5_000_000,            # Max cache entry size: 5MB (default)
    compress: true,                   # Compress cache entries (default)
    key_builder: MyApp.KeyBuilder,   # Custom key builder (optional)
    profiles: %{                      # Cache profiles with different TTL strategies
      results: [ttl_ms: 30_000],     # Short-term results (30 seconds)
      options: [ttl_ms: 300_000],    # Medium-term data (5 minutes)  
      schema: [ttl_ms: 3_600_000]    # Long-term schema info (1 hour)
    },
    default_profile: :results,        # Default profile when none specified
    default_ttl_ms: 60_000           # Fallback TTL (1 minute)
  ]
```

**Type**: `keyword()`  
**Default**: `nil` (no caching)

**Available Adapters:**
- `Lotus.Cache.ETS` - In-memory caching using ETS tables

**Cache Modes:**
- **Default**: Automatic caching when cache is configured
- **`:bypass`**: Skip cache entirely, always query database
- **`:refresh`**: Execute query and update cache with fresh results

For detailed caching configuration and usage, see the [Caching Guide](caching.md).

#### `default_page_size`

Configures the global default page size for windowed pagination. This setting helps prevent performance issues when users query large tables by automatically limiting the number of rows returned when using windowed pagination without an explicit limit.

```elixir
config :lotus,
  default_page_size: 1000  # Default: 1000 rows
```

**Type**: `pos_integer() | nil`  
**Default**: `nil` (falls back to built-in default of 1000)

**How it Works:**

This configuration only applies when using windowed pagination (`window` option) without specifying an explicit `limit`:

```elixir
# Without window option - returns ALL rows (no pagination applied)
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table")
# Could return millions of rows

# With window option but no limit - uses default_page_size
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table", [], window: [])
# Returns max 1000 rows (or your configured default)

# With explicit limit - uses the specified limit (capped at default_page_size)
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table", [], window: [limit: 500])
# Returns max 500 rows

# Limit exceeding default is capped for safety
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table", [], window: [limit: 5000])  
# Returns max 1000 rows (capped at default_page_size)
```

**Precedence Rules:**

1. **Explicit limit in window options**: Takes priority but is capped at `default_page_size`
2. **Configured `default_page_size`**: Used when no explicit limit provided
3. **Built-in default (1000)**: Fallback when `default_page_size` is `nil`

**Performance Benefits:**

- **Prevents accidental large queries**: Users can't accidentally return millions of rows
- **Predictable memory usage**: Limits memory consumption per query
- **Better responsiveness**: Faster query execution with smaller result sets
- **Configurable safety**: Adjust the limit based on your application's needs

**Example Configurations:**

```elixir
# Conservative limit for high-traffic applications
config :lotus, default_page_size: 100

# Moderate limit for typical applications  
config :lotus, default_page_size: 1000

# Higher limit for data analysis environments
config :lotus, default_page_size: 5000

# Disable default limiting (use built-in 1000)
config :lotus, default_page_size: nil
```

> **⚠️ Important**: This setting only affects queries that explicitly use windowed pagination. Queries without the `window` option will return all matching rows regardless of this setting.

### Behavior Options

#### `unique_names`

Determines whether query names must be unique across all saved queries.

```elixir
config :lotus,
  unique_names: true   # Enforce unique names (recommended)
  # or
  unique_names: false  # Allow duplicate names
```

**Type**: `boolean()`
**Default**: `true`

> **⚠️ Important**: The default Lotus migration creates a unique index on query names. If you want to allow duplicate names (`unique_names: false`), you must remove this constraint from your database.

**To allow duplicate query names:**

1. Set `unique_names: false` in your configuration
2. Create a migration to drop the unique constraint:

```elixir
defmodule MyApp.Repo.Migrations.RemoveLotusUniqueNameConstraint do
  use Ecto.Migration

  def up do
    drop_if_exists(unique_index(:lotus_queries, [:name], name: "lotus_queries_name_index"))
    create(index(:lotus_queries, [:name], name: "lotus_queries_name_index"))
  end

  def down do
    drop_if_exists(index(:lotus_queries, [:name], name: "lotus_queries_name_index"))
    create(unique_index(:lotus_queries, [:name], name: "lotus_queries_name_index"))
  end
end
```

3. Run the migration: `mix ecto.migrate`

#### `table_visibility`

Controls which database tables and schemas can be accessed through Lotus queries. This provides an additional security layer beyond read-only execution.

```elixir
config :lotus,
  table_visibility: %{
    # Default rules apply to all repositories unless overridden
    default: [
      allow: [
        # Allow specific tables in all schemas
        "users",                      # Allow 'users' table in any schema
        "orders",                     # Allow 'orders' table in any schema
        # Allow entire schemas (PostgreSQL)
        {"analytics", ~r/.*/},        # All tables in analytics schema
        # Allow tables matching pattern in specific schema
        {"public", ~r/^report_/}      # Tables starting with 'report_' in public
      ],
      deny: [
        # Block sensitive tables across ALL schemas
        "credit_cards",               # Blocks credit_cards in any schema
        "api_keys",                   # Blocks api_keys in any schema  
        # Block tables in specific schema only
        {"public", "internal_logs"},  # Only blocks public.internal_logs
        # Block pattern in specific schema
        {"public", ~r/_internal$/}    # Tables ending with '_internal' in public
      ]
    ],
    # Repository-specific rules override defaults
    analytics: [
      allow: [
        {"analytics", ~r/.*/},        # All tables in analytics schema
        "users",                      # users table in any schema
        "sessions"                    # sessions table in any schema
      ]
    ]
  }
```

**Type**: `map()`
**Default**: `%{}`

**Built-in Protection:**

Lotus automatically blocks access to sensitive system tables:

- **PostgreSQL**: `pg_catalog.*`, `information_schema.*`, `schema_migrations`, `lotus_queries`
- **MySQL**: `information_schema.*`, `mysql.*`, `performance_schema.*`, `sys.*`, `schema_migrations`, `lotus_queries`
- **SQLite**: `sqlite_*`, migration tables, `lotus_queries`

**Rule Formats:**

```elixir
# Bare string - matches table name in ANY schema (PostgreSQL) or no schema (SQLite)
"users"                        # Blocks/allows 'users' table in all schemas
"api_keys"                     # Blocks/allows 'api_keys' in public, reporting, etc.

# Schema-specific tuple (PostgreSQL only)
{"public", "users"}            # Only affects public.users
{"reporting", "api_keys"}      # Only affects reporting.api_keys

# Pattern matching with regex
{"analytics", ~r/^daily_/}     # Tables starting with 'daily_' in analytics schema
~r/^temp_/                     # Tables starting with 'temp_' in any schema (as bare regex)

# Schema-wide rules
{"reporting", ~r/.*/}          # All tables in reporting schema
{~r/test_/, ~r/.*/}           # All tables in schemas starting with 'test_'
```

> **Note**: Bare strings like `"api_keys"` are the simplest way to block sensitive tables across all schemas. Use tuples like `{"public", "api_keys"}` when you need schema-specific control.

**Rule Evaluation:**

1. **Built-in denials** - System tables are always blocked
2. **Allow rules** - If present, only explicitly allowed tables are accessible
3. **Deny rules** - Explicitly denied tables are blocked
4. **Default behavior** - If no allow rules exist, all non-denied tables are accessible

**Per-Repository Rules:**

You can configure different visibility rules for each data source:

```elixir
config :lotus,
  data_sources: %{
    "public" => MyApp.PublicRepo,
    "finance" => MyApp.FinanceRepo
  },
  table_visibility: %{
    # Public data - permissive
    public: [
      deny: ["admin_notes", "internal_logs"]
    ],
    # Financial data - very restrictive
    finance: [
      allow: [
        "monthly_revenue_summary",
        "quarterly_reports"
      ]
    ]
  }
```

### Extension Points

#### `source_adapters`

A list of modules implementing the `Lotus.Source.Adapter` behaviour. Custom adapters let you execute queries against non-Ecto data sources (REST APIs, Elasticsearch, ClickHouse-over-HTTP, gRPC, etc.) through the same public API.

```elixir
config :lotus,
  source_adapters: [
    MyApp.ElasticsearchAdapter,
    MyApp.ClickHouseAdapter
  ],
  data_sources: %{
    "search" => %{adapter: :elasticsearch, url: "http://localhost:9200"},
    "warehouse" => %{adapter: MyApp.ClickHouseAdapter, url: "http://ch:8123"}
  }
```

**Type**: `[module()]` — each module must implement `Lotus.Source.Adapter` with `can_handle?/1` and `wrap/2`. Validated at boot: unloaded modules or modules missing the behaviour raise at `Lotus.Config.reload!/0` rather than at first query.
**Default**: `[]`

When resolving a data source, Lotus checks each `source_adapters` module's `can_handle?/1` against the entry (repo module or map) and dispatches to the first match. If none match, atom entries fall through to the built-in Ecto adapter; map entries raise a clear error. See the [source adapters guide](source-adapters.md) for the full contract and a walkthrough.

#### `source_resolver`

Configures the module responsible for turning repo names or modules into `%Lotus.Source.Adapter{}` structs at query time. The default static resolver reads from `data_sources` and is suitable for most applications.

```elixir
config :lotus,
  source_resolver: MyApp.SourceResolver
```

**Type**: `module()` implementing `Lotus.Source.Resolver`
**Default**: `Lotus.Source.Resolvers.Static`

Use a custom resolver when you need runtime source registration, database-backed source lookup, or per-tenant sources. See the [Custom Resolvers guide](custom-resolvers.md) for contracts, minimal examples, and testing tips.

#### `visibility_resolver`

Configures the module responsible for loading schema, table, and column visibility rules. The default static resolver reads from `schema_visibility`, `table_visibility`, and `column_visibility` application config.

```elixir
config :lotus,
  visibility_resolver: MyApp.VisibilityResolver
```

**Type**: `module()` implementing `Lotus.Visibility.Resolver`
**Default**: `Lotus.Visibility.Resolvers.Static`

Use a custom resolver when visibility rules must change without application restarts, are stored in a database, or vary per tenant or role. See the [Custom Resolvers guide](custom-resolvers.md) for contracts, minimal examples, and testing tips.

## Enabling Write Queries

By default, Lotus blocks all write operations (INSERT, UPDATE, DELETE, DDL) at both the
application level (regex deny list) and the database level (read-only transactions).

To allow writes globally (applies to all queries, including the web UI):

```elixir
# config/config.exs (or config/dev.exs for dev-only)
config :lotus,
  read_only: false
```

You can also enable writes per query without changing the global config:

```elixir
# Insert a record
{:ok, result} = Lotus.run_statement(
  "INSERT INTO notes (body) VALUES ($1) RETURNING id, body",
  ["hello world"],
  read_only: false
)

# Update records
{:ok, result} = Lotus.run_statement(
  "UPDATE users SET active = true WHERE id = $1 RETURNING id",
  [42],
  read_only: false
)
```

> ### Warning {: .warning}
>
> Write queries bypass the application-level deny list. If you don't need writes,
> keep the default `read_only: true`. For maximum safety in production, point Lotus
> at a [read-only database replica](#read-only-repositories-recommended) so that
> writes are impossible at the connection level regardless of options.

Even with `read_only: false`, the following safety checks still apply:

- **Single-statement validation** — multiple statements separated by `;` are still rejected
- **Table visibility rules** — queries against blocked tables are still denied
- **Preflight authorization** — schema and table access controls are still enforced

## Read-Only Repositories (Recommended)

For the strongest guarantee that no writes can occur, point Lotus at an Ecto repository
backed by a **read-only database replica**. This is separate from Lotus's own `read_only`
option — Ecto's `read_only: true` repo option rejects every write at the repository level,
so even `read_only: false` in Lotus cannot bypass it.

### Why Use Read-Only Repositories?

- **Connection-level enforcement**: The repository rejects all writes before they reach the database
- **Immune to option overrides**: Lotus's `read_only: false` has no effect — Ecto blocks writes first
- **Clear intent**: Explicitly declares that a repository is intended only for reading data
- **Defense-in-depth**: Works alongside Lotus's application-level safety checks

### Configuring Read-Only Repositories

Ecto provides built-in support for read-only repositories using the `read_only: true` repo option:

```elixir
# lib/my_app/read_only_repo.ex
defmodule MyApp.ReadOnlyRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres,
    read_only: true  # Ecto rejects all write operations at the repo level
end
```

Configure Lotus to use your read-only repository for data queries:

```elixir
# config/config.exs
config :lotus,
  ecto_repo: MyApp.Repo,           # Use regular repo for storing Lotus queries
  data_sources: %{
    "main" => MyApp.ReadOnlyRepo,  # Use read-only repo for data queries
    "analytics" => MyApp.AnalyticsReadOnlyRepo
  }

# Configure the read-only repository connection
config :my_app, MyApp.ReadOnlyRepo,
  username: "myapp_user",
  password: "secret",
  hostname: "localhost",
  database: "myapp_prod"
```

### How It Interacts with Lotus

When a data source is configured with Ecto's `read_only: true`:

1. **Ecto blocks writes first** — the repo rejects INSERT/UPDATE/DELETE before Lotus is involved
2. **Lotus's `read_only: false` has no effect** — even if you pass it, the repo won't execute writes
3. **Lotus safety checks still apply** — SQL validation, table visibility, and preflight authorization run as usual

```elixir
# Reads work normally
{:ok, result} = Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: "main")

# Writes are blocked by Ecto's read-only repo — even with read_only: false
{:error, _} = Lotus.run_statement(
  "INSERT INTO users (name) VALUES ($1)", ["test"],
  repo: "main", read_only: false
)
```

### Learn More

For comprehensive details on repository configuration options, see the official Ecto documentation: [Replicas and Dynamic Repositories](https://hexdocs.pm/ecto/replicas-and-dynamic-repositories.html).

## Execution Options

While not part of application configuration, Lotus supports runtime options for query execution:

### Timeout Options

```elixir
# Default timeout (5 seconds)
Lotus.run_query(query)

# Custom timeout
Lotus.run_query(query, timeout: 30_000)  # 30 seconds

# Statement-level timeout (PostgreSQL)
Lotus.run_query(query, statement_timeout_ms: 15_000)  # 15 seconds
```

### Connection Options

```elixir
# Use search_path for schema resolution
Lotus.run_query(query, search_path: "analytics, public")
```

## Validation

Lotus validates your configuration at startup. Common validation errors:

### Missing Repository

```elixir
# This will raise ArgumentError during compilation
config :lotus
  # repo: MyApp.Repo  # Missing!
```

**Error**: `Invalid :lotus config: required :ecto_repo option not found, received options: []`

## Configuration Helpers

Lotus provides helper functions to access configuration at runtime:

```elixir
# Get the configured repository
Lotus.repo()
# MyApp.Repo

# Check if unique names are enforced
Lotus.unique_names?()
# true
```

## Multi-Database Support

Lotus supports PostgreSQL, MySQL, and SQLite databases. The migration system automatically detects the adapter and runs the appropriate migrations.

### PostgreSQL Configuration

```elixir
config :my_app, MyApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "my_app_dev",
  pool_size: 10
```

### MySQL Configuration

```elixir
config :my_app, MyApp.MySQLRepo,
  username: "root",
  password: "mysql",
  hostname: "localhost",
  port: 3306,
  database: "my_app_dev",
  pool_size: 10
```

### SQLite Configuration

**Security Note**: SQLite 3.8.0+ (2013) provides enhanced security through `PRAGMA query_only`, which prevents write operations at the database engine level.

```elixir
config :my_app, MyApp.SqliteRepo,
  database: Path.expand("../my_app.db", Path.dirname(__ENV__.file)),
  pool_size: 10
```

### Mixed Database Environments

You can mix PostgreSQL, MySQL, and SQLite repositories:

```elixir
config :lotus,
  ecto_repo: MyApp.Repo,          # PostgreSQL for storage
  default_source: "postgres",     # Default data source for queries
  data_sources: %{
    "postgres" => MyApp.Repo,     # PostgreSQL data
    "mysql" => MyApp.MySQLRepo,   # MySQL data
    "sqlite" => MyApp.SqliteRepo, # SQLite data
    "analytics" => MyApp.AnalyticsRepo  # Another PostgreSQL
  }
```
