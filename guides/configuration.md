# Configuration

This guide covers all configuration options available in Lotus and how to customize the library for your specific needs.

## Basic Configuration

Lotus configuration is typically placed in your `config/config.exs` file:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,     # Repository for Lotus query storage
  default_source: "main",       # Default data source for query execution
  data_sources: %{              # Data sources for executing queries
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  },
  cache: %{                     # Optional caching configuration
    adapter: Lotus.Cache.ETS,   # Cache adapter (ETS for local, Cachex for distributed)
    namespace: "myapp_cache"    # Cache namespace (optional)
  }
```

> ### Renamed in v1.0 {: .warning}
>
> `:ecto_repo`, `:data_repos` and `:default_repo` were renamed to
> `:storage_repo`, `:data_sources` and `:default_source`. There is no
> compatibility shim: the old keys are rejected by configuration validation
> at boot. See the [Upgrading to v1.0 guide](upgrading-to-v1.md).

The full option list is validated with `NimbleOptions` in `Lotus.Config`. Unknown keys are ignored, invalid values raise an `ArgumentError` at boot.

## Configuration Options

### Required Options

#### `storage_repo` (required)

Specifies the Ecto repository where Lotus stores saved queries. This is where the `lotus_queries` table lives.

```elixir
config :lotus,
  storage_repo: MyApp.Repo
```

**Type**: `module()`

The accessor is `Lotus.repo/0` — that name did not change.

#### `data_sources`

A map of data sources where queries can be executed against actual data. This lets Lotus work with multiple databases at the same time.

Keys are friendly names that you use when executing queries. Values are **either** Ecto repository modules (for SQL databases handled by the built-in Ecto adapter) **or** config maps (for non-Ecto adapters like Elasticsearch, ClickHouse-over-HTTP, or any custom `Lotus.Source.Adapter` implementation).

```elixir
config :lotus,
  data_sources: %{
    # Ecto-backed sources (module values) — handled by the built-in Ecto adapter
    "main" => MyApp.Repo,               # Can be the same as storage_repo
    "analytics" => MyApp.AnalyticsRepo,
    "reporting" => MyApp.ReportingRepo,
    "mysql_data" => MyApp.MySQLRepo,    # MySQL repository
    "sqlite_data" => MyApp.SqliteRepo,  # Mix database types

    # Non-Ecto sources (map values) — resolved through a source_adapters entry
    "search" => %{adapter: MyApp.ElasticsearchAdapter, url: "http://localhost:9200"},
    "warehouse" => %{adapter: MyApp.ClickHouseAdapter, url: "http://ch:8123"}
  },
  source_adapters: [MyApp.ElasticsearchAdapter, MyApp.ClickHouseAdapter]
```

**Type**: `%{String.t() => module() | map()}`
**Default**: `%{}`

A map entry with an `:adapter` key naming a module is the canonical form — that module is used directly, with no probing. Entries without `:adapter` are offered to each `source_adapters` module's `can_handle?/1` callback; if two adapters claim the same entry, resolution raises and names both. The rest of the map is opaque to Lotus — the matching adapter's `wrap/2` callback interprets it. See the [source adapters guide](source-adapters.md).

A name that is not in `data_sources` is an error, not a fallback: `Lotus.Source.resolve!/2` raises rather than running the statement against the default source.

#### `default_source`

The data source used when a caller names no source. Required in practice as soon as you configure more than one source.

```elixir
config :lotus,
  default_source: "main",  # Must match a key in data_sources
  data_sources: %{
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  }
```

**Type**: `String.t()`
**Default**: none

**Behavior**:

- **Single source**: when only one data source is configured, it is used as the default even if `default_source` is unset
- **Multiple sources**: set `default_source`, otherwise the first entry of the map wins — which is not a stable order
- **No sources**: `Lotus.default_data_source/0` raises with instructions to configure one
- **Typo protection**: if `default_source` is not a key in `data_sources`, configuration validation raises at boot and lists the configured source names

**Usage Examples:**

```elixir
# Execute against a specific source by name
Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: "analytics")

# Execute against a repository module directly
Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: MyApp.AnalyticsRepo)

# When no source is given, uses the configured default_source
Lotus.run_statement("SELECT COUNT(*) FROM users")  # Uses "main"
```

> **Note**: The execution option is still named `:repo`. It accepts a source name or a repo module.

**Data Source Management:**

```elixir
# List all configured data source names
Lotus.list_data_source_names()
# ["analytics", "main", "reporting", "sqlite_data"]

# Get all configured data sources
Lotus.data_sources()
# %{"analytics" => MyApp.AnalyticsRepo, "main" => MyApp.Repo, ...}

# Get a specific data source by name (raises if not found)
Lotus.get_data_source!("analytics")
# MyApp.AnalyticsRepo

# Get the default source as a {name, value} tuple
Lotus.default_data_source()
# {"main", MyApp.Repo}
```

`get_data_source!/1` and `data_sources/0` return what you configured, so a non-Ecto entry comes back as a map, not a module. To get a resolved `%Lotus.Source.Adapter{}` instead, use `Lotus.Source.get_source!/1`, `Lotus.Source.list_sources/0` and `Lotus.Source.default_source/0`.

> **Note**: The `storage_repo` can also be included in `data_sources` if you want to run queries against the same database where Lotus stores its data. This is common in single-database applications.

### Optional Features

#### `cache`

Configures result and discovery caching. When a cache adapter is configured, Lotus caches query results and schema introspection automatically.

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,        # Cache adapter (required to enable caching)
    namespace: "myapp_cache",        # Cache key namespace (default: "lotus:v1")
    key_builder: MyApp.KeyBuilder,   # Lotus.Cache.KeyBuilder implementation (optional)
    profiles: %{                     # Cache profiles with different TTL strategies
      results: [ttl_ms: 30_000],     # Short-term results (30 seconds)
      options: [ttl_ms: 300_000],    # Medium-term data (5 minutes)
      schema: [ttl_ms: 3_600_000]    # Long-term schema info (1 hour)
    },
    default_profile: :results,       # Default profile when none specified
    default_ttl_ms: 60_000           # Fallback TTL for the :results profile
  }
```

**Type**: `map()` or `nil` — a keyword list is rejected by validation
**Default**: `nil` (no caching)

**Available Adapters:**

- `Lotus.Cache.ETS` — local in-memory caching using ETS
- `Lotus.Cache.Cachex` — distributed caching through [Cachex](https://hexdocs.pm/cachex) (configure at runtime, see the caching guide)

**Cache Modes** (per call, through the `:cache` execution option):

- **Default**: automatic caching when a cache adapter is configured
- **`:bypass`**: skip the cache entirely, always query the source
- **`:refresh`**: execute the query and overwrite the cache entry

For detailed caching configuration and usage, see the [Caching Guide](caching.md).

#### `default_page_size`

Configures the global default page size for windowed pagination. This keeps a user from pulling a whole large table when they page through results without an explicit limit.

```elixir
config :lotus,
  default_page_size: 1000
```

**Type**: `pos_integer() | nil`
**Default**: `nil` (falls back to the built-in default of 1000)

**How it Works:**

This configuration only applies when you use windowed pagination (the `:window` option):

```elixir
# Without window option - returns ALL rows (no pagination applied)
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table")

# With window option but no limit - uses default_page_size
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table", [], window: [])
# Returns max 1000 rows (or your configured default)

# With explicit limit - uses the specified limit (capped at default_page_size)
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table", [], window: [limit: 500])
# Returns max 500 rows

# Limit exceeding the default is capped for safety
{:ok, result} = Lotus.run_statement("SELECT * FROM large_table", [], window: [limit: 5000])
# Returns max 1000 rows
```

**Precedence Rules:**

1. **Explicit limit in window options**: takes priority but is capped at `default_page_size`
2. **Configured `default_page_size`**: used when no explicit limit is given
3. **Built-in default (1000)**: fallback when `default_page_size` is `nil`

`Lotus.Export` uses the same value as its default page size when it streams results.

> **⚠️ Important**: This setting only affects queries that use windowed pagination. Queries without the `window` option return all matching rows.

### Behavior Options

#### `read_only`

```elixir
config :lotus,
  read_only: true  # Default
```

**Type**: `boolean()`
**Default**: `true`

When `true`, Lotus blocks write operations (INSERT, UPDATE, DELETE, DDL) at the application level and runs statements in a read-only transaction where the adapter supports it. See [Enabling Write Queries](#enabling-write-queries) below.

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

#### `allow_unrestricted_resources`

Some adapters cannot tell Lotus which tables or indexes a statement touches — Elasticsearch, for example, gates access at the index level inside the engine. Their `extract_accessed_resources/2` returns `{:unrestricted, reason}`, and preflight blocks the statement unless the operator opts in.

```elixir
config :lotus,
  allow_unrestricted_resources: false  # Default
```

**Type**: `boolean()`
**Default**: `false`

You can opt in globally, or per source through the source's config map:

```elixir
config :lotus,
  allow_unrestricted_resources: false,   # Locked down by default
  data_sources: %{
    "main" => MyApp.Repo,
    "search" => %{
      adapter: MyApp.ElasticsearchAdapter,
      url: "http://localhost:9200",
      allow_unrestricted_resources: true  # This source only
    }
  }
```

The per-source value wins in both directions: `true` opts a single source in under a restrictive global default, and `false` keeps a single source locked down under a permissive one. When a statement is blocked, the error names the source and tells the operator exactly which flag to set.

> ### Warning {: .warning}
>
> Opting in means Lotus trusts the engine's own access control for that
> source. Lotus table and column visibility rules cannot be enforced on
> statements it cannot introspect.

#### `table_visibility`

Controls which database tables can be reached through Lotus queries and discovery. This is a security layer beyond read-only execution.

```elixir
config :lotus,
  table_visibility: %{
    # Default rules apply to all sources unless overridden
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
    # Source-specific rules override defaults
    analytics: [
      allow: [
        {"analytics", ~r/.*/},
        "users",
        "sessions"
      ]
    ]
  }
```

**Type**: `map()`
**Default**: `%{}`

Map keys are matched against the data source name with `to_string/1`, so `analytics:` and `"analytics" =>` both key the `"analytics"` source. The `:default` entry is the fallback.

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
~r/^temp_/                     # Tables starting with 'temp_' in any schema

# Schema-wide rules
{"reporting", ~r/.*/}          # All tables in reporting schema
{~r/test_/, ~r/.*/}            # All tables in schemas starting with 'test_'
```

**Rule Evaluation:**

1. **Built-in denials** — system tables are always blocked
2. **Allow rules** — if present, only explicitly allowed tables are accessible
3. **Deny rules** — explicitly denied tables are blocked
4. **Default behavior** — if no allow rules exist, all non-denied tables are accessible

**Per-Source Rules:**

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

#### `schema_visibility`

Schema-level (namespace-level) rules. Schema rules gate table rules: if a schema is denied, every table in it is blocked no matter what `table_visibility` says.

```elixir
config :lotus,
  schema_visibility: %{
    postgres: [
      allow: ["public", ~r/^tenant_/],
      deny: ["legacy"]
    ],
    mysql: [
      # In MySQL, schemas = databases
      allow: ["app_db", "analytics_db"],
      deny: ["staging_db"]
    ]
  }
```

**Type**: `map()`
**Default**: `%{}`

**Database-specific schema behavior:**

- **PostgreSQL**: true namespaced schemas within a database (`public`, `reporting`, …)
- **MySQL**: schemas are databases
- **SQLite**: schema-less, so schema rules do not apply

#### `column_visibility`

Column-level rules. Lets you hide or mask individual columns per table, rather than blocking the whole table.

```elixir
config :lotus,
  column_visibility: %{
    default: [
      # {table, column, policy} — any schema
      {"users", "password_hash", :omit},
      {"users", "email", [action: :mask, mask: :sha256]},
      # {schema, table, column, policy}
      {"public", "cards", ~r/^pan/, [action: :mask, mask: {:partial, [keep_last: 4]}]},
      # {column, policy} — any schema and table
      {~r/_ssn$/, :error}
    ]
  }
```

**Type**: `map()`
**Default**: `%{}`

Actions are `:allow`, `:omit` (drop the column from results), `:mask` (transform values) and `:error` (fail the query). Mask strategies are `:null`, `:sha256`, `{:fixed, value}` and `{:partial, [keep_last: 4, replacement: "*"]}`. The `show_in_schema?` option (default `true`) controls whether the column still appears in introspection. `Lotus.Visibility.Policy` has builder functions (`Policy.column_mask/1`, `Policy.column_omit/0`) for the same rules.

See the [Visibility Guide](visibility.md) for the full rule grammar and worked examples.

#### `middleware`

Hooks that run around query execution and schema discovery.

```elixir
config :lotus,
  middleware: %{
    before_query: [{MyApp.TenantPredicatePlug, []}],
    after_query: [{MyApp.AuditPlug, []}],
    after_list_tables: [{MyApp.TableFilterPlug, []}]
  }
```

**Type**: `map()` or `nil` — `%{event => [{Module, opts}]}`
**Default**: `nil`

**Events**: `:before_query`, `:after_query`, `:after_list_schemas`, `:after_list_tables`, `:after_describe_table`, `:after_list_relations`, `:after_discover`.

In v1.0 the payload key for the data source is `:source` (it was `:repo`), and `:before_query` / `:after_query` carry a `%Lotus.Query.Statement{}` under `:statement` instead of separate `:sql` and `:params` keys. A `:before_query` plug that returns `{:cont, %{payload | statement: rewritten}}` changes what actually executes, and the rewritten statement is the one that sanitization and preflight then check. See the [Middleware Guide](middleware.md).

#### `ai`

AI-powered query generation, explanation and optimization.

```elixir
config :lotus,
  ai: [
    enabled: true,
    model: "openai:gpt-4o",
    api_key: {:system, "OPENAI_API_KEY"}
  ]
```

**Type**: `keyword()`
**Default**: `[]` (AI features disabled)

**Options:**

- `:enabled` (`boolean()`) — enable AI features. Default `false`
- `:model` (`String.t()`) — a ReqLLM model string, e.g. `"openai:gpt-4o"`, `"anthropic:claude-opus-4"`. Default `"openai:gpt-4o"`
- `:api_key` (`String.t()` or `{:system, "ENV_VAR"}`) — provider API key

Without a resolvable API key, AI calls return `{:error, :api_key_not_configured}`. See the [AI Query Generation Guide](ai_query_generation.md).

### Extension Points

#### `source_adapters`

A list of modules implementing the `Lotus.Source.Adapter` behaviour. Custom adapters let you execute queries against non-Ecto data sources (REST APIs, Elasticsearch, ClickHouse-over-HTTP, gRPC, …) through the same public API.

```elixir
config :lotus,
  source_adapters: [
    MyApp.ElasticsearchAdapter,
    MyApp.ClickHouseAdapter
  ],
  data_sources: %{
    "search" => %{adapter: MyApp.ElasticsearchAdapter, url: "http://localhost:9200"},
    "warehouse" => %{adapter: MyApp.ClickHouseAdapter, url: "http://ch:8123"}
  }
```

**Type**: `[module()]` — each module must be loaded and declare `@behaviour Lotus.Source.Adapter`. Validated at boot: an unloaded module or one missing the behaviour raises with a message naming the module, instead of failing at first query.
**Default**: `[]`

A map entry naming its adapter with `:adapter` goes straight to that module. Otherwise Lotus asks each `source_adapters` module's `can_handle?/1`; two claimants raise and name both. Module entries with no claimant fall through to the built-in Ecto adapter. See the [source adapters guide](source-adapters.md) for the full contract.

#### `trusted_source_adapters`

Adapter modules whose `ai_context/1` free-form text (`:syntax_notes`, `:error_patterns`, capability reasons) is allowed into the LLM prompt unchanged.

```elixir
config :lotus,
  trusted_source_adapters: [MyApp.ClickHouseAdapter]
```

**Type**: `[module()]`
**Default**: `[]`

The built-in `Lotus.Source.Adapters.Ecto` and its per-dialect wrappers (Postgres, MySQL, SQLite3) are always trusted. For an untrusted adapter, only the `:language` identifier reaches the prompt — the free-form fields are stripped and capability reasons are replaced with a generic fallback, to bound the blast radius of prompt injection through third-party adapter text.

#### `source_resolver`

The module that turns a source name or repo module into a `%Lotus.Source.Adapter{}` struct at query time. The default static resolver reads from `data_sources`.

```elixir
config :lotus,
  source_resolver: MyApp.SourceResolver
```

**Type**: `module()` implementing `Lotus.Source.Resolver`
**Default**: `Lotus.Source.Resolvers.Static`

Use a custom resolver when you need runtime source registration, database-backed source lookup, or per-tenant sources. See the [Custom Resolvers guide](custom-resolvers.md).

#### `visibility_resolver`

The module that loads schema, table and column visibility rules. The default static resolver reads from `schema_visibility`, `table_visibility` and `column_visibility`.

```elixir
config :lotus,
  visibility_resolver: MyApp.VisibilityResolver
```

**Type**: `module()` implementing `Lotus.Visibility.Resolver`
**Default**: `Lotus.Visibility.Resolvers.Static`

Resolver callbacks (`schema_rules_for/2`, `table_rules_for/2`, `column_rules_for/2`) take the caller's `:scope` as a second argument, so rules can vary per tenant or role. The shipped static resolver ignores it. In v1.0 these rules are enforced at execution as well as in the schema browser: a table hidden from a scope cannot be queried by that scope either. See the [Custom Resolvers guide](custom-resolvers.md) and the [Visibility Guide](visibility.md).

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

- **Connection-level enforcement**: the repository rejects all writes before they reach the database
- **Immune to option overrides**: Lotus's `read_only: false` has no effect — Ecto blocks writes first
- **Clear intent**: explicitly declares that a repository is intended only for reading data
- **Defense-in-depth**: works alongside Lotus's application-level safety checks

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
  storage_repo: MyApp.Repo,        # Use regular repo for storing Lotus queries
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
3. **Lotus safety checks still apply** — statement validation, table visibility, and preflight authorization run as usual

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

While not part of application configuration, Lotus supports runtime options for query execution. `Lotus.run_query/2` and `Lotus.run_statement/3` accept:

`:timeout`, `:statement_timeout_ms`, `:read_only`, `:search_path`, `:repo`, `:vars`, `:cache`, `:window`, `:filters`, `:sorts`, `:context`, `:scope`.

### Timeout Options

```elixir
# Default timeout (15 seconds)
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

### Caller Identity Options

Two options carry caller identity through the pipeline, and they are not interchangeable:

```elixir
# :context — opaque value handed to middleware and telemetry. NOT part of the cache key.
Lotus.run_query(query, context: %{request_id: "abc", actor: current_user})

# :scope — handed to the visibility resolver AND hashed into the cache key.
Lotus.run_query(query, scope: %{tenant_id: 42})
```

If your middleware or visibility rules change what a query returns per actor, that identity must go in `:scope`, not only in `:context` — otherwise two different actors share one cache entry. See [Scope and cache correctness](caching.md#scope-and-cache-correctness).

## Validation

Lotus validates your configuration on first access and caches the result in `:persistent_term`. Common validation errors:

### Missing Storage Repository

```elixir
config :lotus,
  data_sources: %{"main" => MyApp.Repo}
  # storage_repo missing!
```

**Error**: `Invalid :lotus config: required :storage_repo option not found`

### Default Source Not In Data Sources

```elixir
config :lotus,
  storage_repo: MyApp.Repo,
  default_source: "primary",         # typo
  data_sources: %{"main" => MyApp.Repo}
```

**Error**: `Invalid :lotus config: :default_source "primary" is not a key in :data_sources. Configured sources: ["main"]`

### Pre-v1 Keys

Old key names are not normalized. `ecto_repo`, `data_repos` and `default_repo` are simply not part of the schema, so `storage_repo` reads as missing and every source lookup comes up empty. See the [Upgrading to v1.0 guide](upgrading-to-v1.md).

### Reloading Configuration

Because the validated configuration is cached, changing `:lotus` application environment after boot (in tests, for example) has no effect until you refresh it:

```elixir
Application.put_env(:lotus, :default_page_size, 50)
Lotus.Config.reload!()
```

## Configuration Helpers

Lotus provides helper functions to read configuration at runtime:

```elixir
# Get the storage repository
Lotus.repo()
# MyApp.Repo

# Check if unique names are enforced
Lotus.unique_names?()
# true

# Read-only mode
Lotus.Config.read_only?()
# true

# The whole validated configuration
Lotus.Config.all()

# Any single key
Lotus.Config.get(:default_page_size)
```

## Multi-Database Support

Lotus supports PostgreSQL, MySQL, and SQLite databases out of the box. The migration system automatically detects the adapter and runs the appropriate migrations.

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

You can mix PostgreSQL, MySQL, and SQLite repositories, and add non-Ecto sources alongside them:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,       # PostgreSQL for storage
  default_source: "postgres",     # Default data source for queries
  data_sources: %{
    "postgres" => MyApp.Repo,     # PostgreSQL data
    "mysql" => MyApp.MySQLRepo,   # MySQL data
    "sqlite" => MyApp.SqliteRepo, # SQLite data
    "analytics" => MyApp.AnalyticsRepo  # Another PostgreSQL
  }
```
