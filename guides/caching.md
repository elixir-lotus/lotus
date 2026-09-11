# Caching Guide

This guide covers Lotus's comprehensive caching system, which improves query performance by storing and reusing results from expensive database operations.

Lotus does not enable caching by default. To turn it on, configure a cache adapter under `config :lotus` — Lotus's supervisor starts automatically with your app and will boot the configured cache backend for you.

## Overview

Lotus provides a flexible caching system with the following features:

- **Pluggable adapters** - Support for different cache backends
- **TTL-based expiration** - Automatic cache invalidation based on time-to-live
- **Cache profiles** - Different caching strategies for different use cases
- **Tag-based invalidation** - Selective cache clearing using tags
- **Multiple cache modes** - Fine-grained control over cache behavior
- **Namespace support** - Cache isolation and organization

## Quick Start

### Basic Configuration

Lotus ships with built-in cache profiles (`:results`, `:schema`, `:options`) that work without any configuration. To enable caching, just add the cache adapter to your Lotus configuration:

```elixir
# config/config.exs
config :lotus,
  ecto_repo: MyApp.Repo,
  data_sources: %{
    "main" => MyApp.Repo
  },
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus"
  }
```

**Note**: Even with minimal configuration, you get sensible caching defaults:

- Query results cached for 60 seconds (`:results` profile)
- Schema information cached for 1 hour (`:schema` profile)
- Options/reference data cached for 5 minutes (`:options` profile)

### OTP Application Setup

Lotus is an OTP application: as long as `:lotus` is in your `mix.exs` dependencies, its supervisor starts automatically with your app and boots the cache backend declared under `config :lotus, :cache`. No supervision-tree wiring is required on your end.

The `Lotus.Cache.ETS` GenServer is always started by the supervisor to ensure cache tables are available. If you configure a different cache adapter (e.g., `Lotus.Cache.Cachex`), it is started in addition to the ETS tables.

> **Note:** If you accidentally include `Lotus` as a child in your own supervision tree, the double-start is handled gracefully — `Lotus.Supervisor` returns `{:ok, pid}` for an already-running instance.

### Using Cache in Queries

Once configured and started, caching works automatically:

```elixir
# First call - executes query and caches result
{:ok, result1} = Lotus.run_statement("SELECT COUNT(*) FROM users")

# Second call - returns cached result (much faster!)
{:ok, result2} = Lotus.run_statement("SELECT COUNT(*) FROM users")
```

## Configuration

### Cache Adapter

Currently, Lotus supports two cache adapters:

1. `Lotus.Cache.ETS` - Local-only in-memory caching using ETS, implemented as a GenServer with automatic expiration cleanup
2. `Lotus.Cache.Cachex` - Distributed caching using [Cachex](https://hexdocs.pm/cachex)

#### ETS Adapter

The `Lotus.Cache.ETS` adapter provides in-memory caching using Erlang Term Storage (ETS):

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus",    # Optional namespace
    max_bytes: 5_000_000,       # Max entry size: 5MB (default)
    compress: true              # Compress cache entries (default: true)
  }
```

#### Cachex Adapter

The `Lotus.Cache.Cachex` adapter uses the Cachex library for distributed setups.

First, add Cachex to your dependencies in `mix.exs`:

```elixir
{:cachex, "~> 4.0"}
```

Then, configure Lotus to use Cachex in `config/runtime.exs` (or wherever your runtime config is located):

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.Cachex,
    namespace: "myapp_lotus",    # Optional namespace
    cachex_opts: [] # Optional Cachex options (see Cachex docs)
    # You can set other Lotus cache config options here as well
  }
```

**Note: You MUST configure Cachex at runtime. This is because Cachex uses Records, which are not available in compile-time configuration.**

`cachex_opts` [accepts all options supported by Cachex](https://hexdocs.pm/cachex/cache-routers.html#default-routers). If not specified, the default Cachex configuration is used is:

```elixir
[router: router(module: Cachex.Router.Ring, options: [monitor: true])]
```

### Cache Profiles

Profiles allow you to configure different TTL strategies for different types of queries. Lotus comes with three predefined profiles that are always available:

#### Predefined Profiles

Lotus ships with these built-in cache profiles:

- **`:results`** - 60 seconds TTL - For query results and fast-changing data
- **`:schema`** - 1 hour TTL - For database schema information that changes rarely
- **`:options`** - 5 minutes TTL - For dropdown options and reference data

These profiles are always available, even without any cache configuration. You can override their settings or add custom profiles:

```elixir
config :lotus,
  cache: [
    adapter: Lotus.Cache.ETS,
    profiles: %{
      # Override built-in profiles
      results: [ttl_ms: 30_000],      # Override default 60s to 30s
      schema: [ttl_ms: 7_200_000],    # Override default 1h to 2h
      options: [ttl_ms: 600_000],     # Override default 5m to 10m

      # Add custom profiles
      reports: [ttl_ms: 1_800_000]    # 30 minutes - business reports
    },
    default_profile: :results,        # Used when no profile specified
    default_ttl_ms: 60_000           # 1 minute - fallback TTL
  ]
```

#### Profile Fallback Behavior

When you don't configure cache profiles:

- `:results` uses 60 seconds TTL
- `:schema` uses 1 hour TTL
- `:options` uses 5 minutes TTL

When you configure `default_ttl_ms` but don't specify `:results` profile:

- `:results` uses your `default_ttl_ms` value
- `:schema` and `:options` keep their built-in defaults

### Namespace Support

Namespaces provide cache isolation and organization:

```elixir
config :lotus,
  cache: [
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus"  # Optional namespace for cache isolation
  ]
```

## Cache Modes

Lotus provides three cache modes for different scenarios:

### Default Mode (Automatic Caching)

When no cache mode is specified, Lotus automatically caches results:

```elixir
# Uses cache if available, otherwise queries database and caches result
{:ok, result} = Lotus.run_statement("SELECT * FROM products")
```

### Bypass Mode

Skip cache entirely - always query the database:

```elixir
# Always hits database, never reads from or writes to cache
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [], cache: :bypass)
```

**Use cases:**

- Real-time data requirements
- Testing scenarios
- One-off queries where cache isn't beneficial

### Refresh Mode

Execute query and update cache with fresh results:

```elixir
# Executes query AND updates cache with new result
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [], cache: :refresh)
```

**Use cases:**

- Force cache refresh after data changes
- Scheduled cache warming
- Manual cache updates

## Cache Options

### Profile Selection

Choose a specific cache profile for a query:

```elixir
# Use the 'schema' profile (longer TTL)
{:ok, tables} = Lotus.run_statement("SELECT name FROM sqlite_master", [], cache: [profile: :schema])
```

### TTL Override

Override the default TTL for specific queries:

```elixir
# Cache for exactly 2 minutes regardless of profile
{:ok, result} = Lotus.run_statement("SELECT * FROM users", [], cache: [ttl_ms: 120_000])
```

### Tag-Based Caching

Tag cache entries for selective invalidation:

```elixir
# Tag this cache entry
{:ok, user} = Lotus.run_statement("SELECT * FROM users WHERE id = $1", [123],
  cache: [tags: ["user:123", "user_data"]])

# Later, invalidate all entries with these tags
Lotus.Cache.invalidate_tags(["user:123"])
```

### Combined Options

You can combine multiple cache options:

```elixir
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [],
  cache: [
    profile: :reports,
    ttl_ms: 600_000,  # Override profile TTL
    tags: ["products", "inventory"]
  ])
```

## Cache Key Generation

Lotus generates cache keys based on:

- **SQL statement** - The actual query text
- **Parameters** - Query parameters and variable values
- **Repository** - Which database the query targets
- **Search path** - PostgreSQL schema search path
- **Scope** - When non-nil, hashed into discovery cache keys
- **Lotus version** - Ensures cache invalidation across version upgrades

This ensures that different queries, even with slight variations, get separate cache entries.

### Custom Key Builder

The default key generation can be replaced by implementing the `Lotus.Cache.KeyBuilder` behaviour. This is useful when you need to incorporate additional context into cache keys or use a different hashing strategy.

```elixir
defmodule MyApp.CustomKeyBuilder do
  @behaviour Lotus.Cache.KeyBuilder

  @impl true
  def discovery_key(params, scope) do
    # Add environment to discovery keys
    env = Application.get_env(:my_app, :env, :prod)

    Lotus.Cache.KeyBuilder.Default.discovery_key(
      %{params | components: Tuple.append(params.components, env)},
      scope
    )
  end

  @impl true
  def result_key(body, bound, opts, scope) do
    # Delegate to default for result keys
    Lotus.Cache.KeyBuilder.Default.result_key(body, bound, opts, scope)
  end
end
```

Configure it in your cache settings:

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,
    key_builder: MyApp.CustomKeyBuilder
  }
```

The behaviour defines two callbacks:

- `discovery_key/2` — builds keys for schema introspection cache entries (list_tables, get_table_schema, etc.)
- `result_key/4` — builds keys for query result cache entries (accepts `scope` as the 4th argument)

When no `key_builder` is configured, `Lotus.Cache.KeyBuilder.Default` is used, which preserves the built-in key generation logic.

## Schema Function Caching

All Lotus schema introspection functions are automatically cached:

- `Lotus.list_tables/2` - Lists tables and views in database
- `Lotus.describe_table/3` - Gets column information for tables
- `Lotus.get_table_stats/3` - Gets row counts and table statistics
- `Lotus.list_relations/2` - Lists tables with schema information

### Default Cache Behavior

Schema functions use different cache profiles by default:

```elixir
# Schema metadata - uses :schema profile (1 hour TTL)
{:ok, tables} = Lotus.list_tables("postgres")
{:ok, schema} = Lotus.get_table_schema("postgres", "users")
{:ok, relations} = Lotus.list_relations("postgres")

# Table statistics - uses :results profile (30 seconds TTL)
{:ok, stats} = Lotus.get_table_stats("postgres", "users")
```

**Why different profiles?**

- **Schema metadata** (tables, columns) changes rarely, so longer caching (1 hour) is safe
- **Table statistics** (row counts) change frequently, so shorter caching (30 seconds) keeps data fresh

### Schema Cache Options

Schema functions support all cache modes and options:

```elixir
# Bypass cache for fresh data
{:ok, tables} = Lotus.list_tables("postgres", cache: :bypass)

# Refresh cache with latest data
{:ok, schema} = Lotus.get_table_schema("postgres", "users", cache: :refresh)

# Use custom profile
{:ok, stats} = Lotus.get_table_stats("postgres", "users",
  cache: [profile: :options])  # 5 minute TTL

# Override TTL
{:ok, relations} = Lotus.list_relations("postgres",
  cache: [ttl_ms: 600_000])  # 10 minutes

# Add tags for invalidation
{:ok, schema} = Lotus.get_table_schema("postgres", "products",
  cache: [tags: ["schema:products", "metadata"]])
```

### Schema Cache Invalidation

Schema information is automatically tagged for selective invalidation:

```elixir
# After schema changes (migrations, table creation, etc.)
Lotus.Cache.invalidate_tags(["repo:postgres", "schema:list_tables"])

# After specific table changes
Lotus.Cache.invalidate_tags(["table:public.users"])
```

**Automatic tags added:**

- `"repo:#{repo_name}"` - Repository-specific data
- `"schema:#{function_name}"` - Function-specific data
- `"table:#{schema}.#{table}"` - Table-specific data (when applicable)
- `"scope:<digest>"` - Scope-specific data (when a non-nil `:scope` option is passed)

### Per-Scope Cache Invalidation

When using the `:scope` option on discovery or query execution functions, each cached entry is automatically tagged with a scope digest. This lets you invalidate all cached entries for a specific scope without flushing the entire cache:

```elixir
# Populate cache for different scopes
{:ok, _} = Lotus.list_tables("postgres", scope: %{tenant_id: 1})
{:ok, _} = Lotus.list_tables("postgres", scope: %{tenant_id: 2})

# Invalidate only tenant 1's cached entries
:ok = Lotus.invalidate_scope(%{tenant_id: 1})

# Tenant 2's cache is untouched — this is still a cache hit
{:ok, _} = Lotus.list_tables("postgres", scope: %{tenant_id: 2})
```

This is useful when visibility rules change for a specific scope (e.g. a tenant's permissions are updated) and you need to clear stale cache entries without affecting other scopes. `invalidate_scope/1` clears both discovery and result cache entries tagged with the given scope.

`invalidate_scope/1` accepts any non-nil term and returns `:ok`. Passing `nil` is a no-op (there is no scope tag to invalidate).

When passing `:scope` to query execution (`run_query/2`, `run_statement/3`), the scope is hashed into the result cache key so different scopes produce independent cached results. This is important when the database uses row-level security (RLS) policies, middleware rewrites queries per-scope, or a `SET ROLE` / session variable changes what data the query sees.

## Working with run_query

Saved queries (`run_query`) support all the same cache options:

```elixir
# Automatic caching based on configuration
{:ok, result} = Lotus.run_query(query_id)

# Bypass cache
{:ok, result} = Lotus.run_query(query_id, cache: :bypass)

# Use specific profile
{:ok, result} = Lotus.run_query(query_id, cache: [profile: :reports])

# Tag for invalidation
{:ok, result} = Lotus.run_query(query_id,
  cache: [tags: ["query:#{query_id}", "dashboard"]])
```

## Cache Management

### Manual Cache Invalidation

Invalidate cache entries by tags:

```elixir
# Invalidate specific entries
Lotus.Cache.invalidate_tags(["user:123"])

# Invalidate multiple tags
Lotus.Cache.invalidate_tags(["user_data", "reports", "dashboard"])

# Invalidate all cached discovery entries for a specific scope
Lotus.invalidate_scope(%{tenant_id: 42})
```

### Automatic Tagging

Lotus automatically adds these tags to cached entries:

- `"query:#{query_id}"` - For run_query calls
- `"repo:#{repo_name}"` - For the database repository used
- `"schema:#{function_name}"` - For Schema function calls (list_tables, get_table_schema, etc.)
- `"table:#{schema}.#{table}"` - For table-specific Schema operations

You can add your own tags in addition to these automatic ones.

## Performance Considerations

### Cache Effectiveness

Monitor cache effectiveness by observing query performance improvements and application response times. Future versions may include cache statistics and telemetry integration.

### Memory Usage

ETS cache memory grows with cached data. Consider:

- **Appropriate TTLs** - Don't cache data longer than needed
- **Selective caching** - Use `:bypass` for large result sets that aren't reused
- **Size limits** - Large cache entries are automatically rejected (default: 5MB, configurable)
- **Regular cleanup** - TTL-based expiration handles this automatically

### Cache Warming

Pre-populate cache with commonly used queries:

```elixir
# During application startup or scheduled jobs
{:ok, _} = Lotus.run_statement("SELECT * FROM lookup_tables", [], cache: :refresh)
{:ok, _} = Lotus.run_query(dashboard_query_id, cache: :refresh)
```

## Best Practices

### Profile Strategy

Lotus provides sensible defaults for the built-in profiles, but you can customize them based on your needs:

```elixir
config :lotus,
  cache: [
    profiles: %{
      # Built-in profiles (customize as needed)
      results: [ttl_ms: 30_000],      # Default: 60s - Fast-changing data
      options: [ttl_ms: 300_000],     # Default: 5m - Reference data
      schema: [ttl_ms: 3_600_000],    # Default: 1h - Schema information

      # Add custom profiles for specific use cases
      reports: [ttl_ms: 1_800_000]    # 30 minutes - Business reports
    }
  ]
```

**Default TTL Guidelines:**

- **`:results` (60s)** - Query results, user data, transactional information
- **`:options` (5m)** - Dropdown options, lookup tables, reference data
- **`:schema` (1h)** - Database schema, table structure, metadata

### Tagging Strategy

```elixir
# User-specific data
cache: [tags: ["user:#{user_id}", "user_data"]]

# Feature-specific data
cache: [tags: ["dashboard", "reports"]]

# Entity-specific data
cache: [tags: ["product:#{product_id}", "inventory"]]
```

### When to Use Each Mode

- **Default mode**: Most queries - let cache system optimize automatically
- **`:bypass` mode**: Real-time data, large one-off queries, testing
- **`:refresh` mode**: After data updates, scheduled cache warming, manual refresh

### Cache Invalidation

```elixir
# After updating user data
User.update(user, %{name: "New Name"})
Lotus.Cache.invalidate_tags(["user:#{user.id}"])

# After bulk data updates
Products.bulk_update()
Lotus.Cache.invalidate_tags(["products", "inventory"])

# After schema changes (migrations, DDL operations)
Ecto.Migrator.run(MyApp.Repo, :up, all: true)
Lotus.Cache.invalidate_tags(["repo:postgres", "schema:list_tables"])

# After table-specific changes
alter table(:users) do
  add :new_column, :string
end
Lotus.Cache.invalidate_tags(["table:public.users"])

# After tenant permissions change — clear only that tenant's cached entries
Lotus.invalidate_scope(%{tenant_id: tenant.id})
```

## Troubleshooting

### Cache Not Working

1. **Check configuration**: Ensure a cache adapter is configured under `config :lotus, :cache`
2. **Check the `:lotus` app is running**: Lotus's supervisor starts automatically with the `:lotus` OTP app, so make sure it isn't excluded from `included_applications` or otherwise prevented from starting
3. **Verify identical queries**: Cache keys are generated from exact SQL + params
4. **Check TTL**: Ensure cache hasn't expired between calls

**Common Error**: `** (ArgumentError) argument error` or `:noproc` errors usually mean the `:lotus` application failed to boot. Since the ETS cache GenServer is always started by the supervisor, cache tables should be available as long as `:lotus` is running.

### Memory Issues

1. **Review TTL settings**: Shorter TTLs = less memory usage
2. **Use selective caching**: Don't cache large result sets unnecessarily
3. **Monitor cache size**: Check ETS table memory usage

### Performance Issues

1. **Cache hit ratio**: Low hit ratio may indicate poor cache strategy
2. **TTL tuning**: Balance between data freshness and cache effectiveness
3. **Query optimization**: Cache works best with optimized queries
