# Caching Guide

This guide covers Lotus's caching system, which improves query performance by storing and reusing results from expensive database operations.

Lotus does not enable caching by default. To turn it on, configure a cache adapter under `config :lotus` — Lotus's supervisor starts automatically with your app and will boot the configured cache backend for you.

## Overview

Lotus provides a flexible caching system with the following features:

- **Pluggable adapters** — support for different cache backends
- **TTL-based expiration** — automatic cache invalidation based on time-to-live
- **Cache profiles** — different caching strategies for different use cases
- **Tag-based invalidation** — selective cache clearing using tags
- **Scope-aware keys** — per-actor or per-tenant result isolation
- **Pluggable key builders** — replace the key scheme through a behaviour
- **Multiple cache modes** — fine-grained control over cache behavior
- **Namespace support** — cache isolation and organization

## Quick Start

### Basic Configuration

Lotus ships with built-in cache profiles (`:results`, `:schema`, `:options`) that work without any configuration. To enable caching, add a cache adapter to your Lotus configuration:

```elixir
# config/config.exs
config :lotus,
  storage_repo: MyApp.Repo,
  data_sources: %{
    "main" => MyApp.Repo
  },
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus"
  }
```

> **The `:cache` value must be a map.** Configuration validation accepts a map
> or `nil`; a keyword list raises an `ArgumentError` at boot.

**Note**: Even with minimal configuration, you get sensible caching defaults:

- Query results cached for 60 seconds (`:results` profile)
- Schema information cached for 1 hour (`:schema` profile)
- Options/reference data cached for 5 minutes (`:options` profile)

### OTP Application Setup

Lotus is an OTP application: as long as `:lotus` is in your `mix.exs` dependencies, its supervisor starts automatically with your app and boots the cache backend declared under `config :lotus, :cache`. No supervision-tree wiring is required on your end.

The `Lotus.Cache.ETS` GenServer is always started by the supervisor to ensure cache tables are available. If you configure a different cache adapter (e.g. `Lotus.Cache.Cachex`), it is started in addition to the ETS tables.

> **Note:** If you accidentally include `Lotus` as a child in your own supervision tree, the double-start is handled gracefully — `Lotus.Supervisor` returns `{:ok, pid}` for an already-running instance.

### Using Cache in Queries

Once configured and started, caching works automatically:

```elixir
# First call - executes query and caches result
{:ok, result1} = Lotus.run_statement("SELECT COUNT(*) FROM users")

# Second call - returns cached result
{:ok, result2} = Lotus.run_statement("SELECT COUNT(*) FROM users")
```

## Configuration

### Cache Adapter

Lotus ships with two cache adapters:

1. `Lotus.Cache.ETS` — local-only in-memory caching using ETS, implemented as a GenServer with automatic expiration cleanup
2. `Lotus.Cache.Cachex` — distributed caching using [Cachex](https://hexdocs.pm/cachex)

#### ETS Adapter

The `Lotus.Cache.ETS` adapter provides in-memory caching using Erlang Term Storage (ETS):

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus"
  }
```

#### Cachex Adapter

The `Lotus.Cache.Cachex` adapter uses the Cachex library for distributed setups.

First, add Cachex to your dependencies in `mix.exs`:

```elixir
{:cachex, "~> 4.0"}
```

Then configure Lotus to use Cachex in `config/runtime.exs` (or wherever your runtime config lives):

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.Cachex,
    namespace: "myapp_lotus",
    cachex_opts: [] # Optional Cachex options (see Cachex docs)
  }
```

**Note: You MUST configure Cachex at runtime. This is because Cachex uses Records, which are not available in compile-time configuration.**

`cachex_opts` [accepts all options supported by Cachex](https://hexdocs.pm/cachex/cache-routers.html#default-routers). If not specified, the default Cachex configuration used is:

```elixir
[router: router(module: Cachex.Router.Ring, options: [monitor: true])]
```

### Cache Profiles

Profiles let you configure different TTL strategies for different kinds of data. Lotus comes with three predefined profiles that are always available.

#### Predefined Profiles

- **`:results`** — 60 seconds TTL — for query results and fast-changing data
- **`:schema`** — 1 hour TTL — for database schema information that changes rarely
- **`:options`** — 5 minutes TTL — for dropdown options and reference data

These profiles are always available, even without any cache configuration. You can override their settings or add custom profiles:

```elixir
config :lotus,
  cache: %{
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
    default_ttl_ms: 60_000            # Fallback TTL
  }
```

#### Profile Fallback Behavior

When you don't configure cache profiles:

- `:results` uses 60 seconds TTL
- `:schema` uses 1 hour TTL
- `:options` uses 5 minutes TTL

When you configure `default_ttl_ms` but don't define a `:results` profile:

- `:results` uses your `default_ttl_ms` value
- `:schema` and `:options` keep their built-in defaults

A profile name that is not configured and is not one of the three built-ins falls back to `default_ttl_ms`, and then to 60 seconds.

### Namespace Support

The namespace is prefixed to every cache key, which isolates one app's entries from another sharing the same backend:

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus"  # Default: "lotus:v1"
  }
```

## Cache Modes

Lotus provides three cache modes for different scenarios.

### Default Mode (Automatic Caching)

When no cache mode is specified, Lotus automatically caches results:

```elixir
# Uses cache if available, otherwise queries the source and caches the result
{:ok, result} = Lotus.run_statement("SELECT * FROM products")
```

### Bypass Mode

Skip the cache entirely — always query the source:

```elixir
# Always hits the database, never reads from or writes to cache
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [], cache: :bypass)
```

**Use cases:**

- Real-time data requirements
- Testing scenarios
- One-off queries where cache isn't beneficial

### Refresh Mode

Execute the query and overwrite the cache entry with the fresh result:

```elixir
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [], cache: :refresh)
```

**Use cases:**

- Force cache refresh after data changes
- Scheduled cache warming
- Manual cache updates

The mode atoms also work inside the option list, so you can combine a mode with other cache options:

```elixir
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [],
  cache: [:refresh, profile: :options])
```

## Cache Options

### Profile Selection

Choose a specific cache profile for a query:

```elixir
{:ok, result} = Lotus.run_statement("SELECT * FROM countries", [], cache: [profile: :options])
```

### TTL Override

Override the profile TTL for specific queries:

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

### Entry Size and Compression

Cache entries are serialized and, by default, compressed. Entries larger than `max_bytes` are silently not cached — the query still returns its result.

```elixir
# Don't cache this result if it serializes to more than 1 MB
{:ok, result} = Lotus.run_statement("SELECT * FROM events", [], cache: [max_bytes: 1_000_000])

# Skip compression for a result that doesn't compress well
{:ok, result} = Lotus.run_statement("SELECT * FROM blobs", [], cache: [compress: false])
```

**Defaults**: `max_bytes: 5_000_000`, `compress: true`. Both are per-call options, honored by the ETS and Cachex adapters.

### Combined Options

```elixir
{:ok, result} = Lotus.run_statement("SELECT * FROM products", [],
  cache: [
    profile: :reports,
    ttl_ms: 600_000,  # Override profile TTL
    tags: ["products", "inventory"]
  ])
```

## Cache Key Generation

Lotus builds two kinds of cache key.

**Result keys** (`run_query/2`, `run_statement/3`) hash:

- **Statement body** — the adapter-native payload (SQL text for Ecto sources, a JSON/DSL term for others)
- **Bound values** — variable bindings or positional parameters, including the pagination window
- **Data source name** — which source the statement targets
- **Search path** — the schema search path, when set
- **Lotus version** — so entries do not survive an upgrade
- **Scope** — when non-nil, its digest is appended to the key

**Discovery keys** (schema introspection) hash the operation kind, the source name, the kind-specific components (such as schema and table name), the Lotus version, and the scope digest when set.

### Scope and cache correctness

The result cache key includes `:scope`. It does **not** include `:context`.

That distinction matters. `:context` is an opaque value for middleware and telemetry — an audit trail. `:scope` is the identity that Lotus treats as part of the cache identity and hands to the visibility resolver.

> ### Warning {: .warning}
>
> If middleware rewrites statements per actor, or your column policies mask
> values per actor, and the actor is carried only in `:context`, then two
> different actors running the same statement share one cache entry — and
> the second actor is served the first actor's rows. Pass a `:scope` that
> identifies the actor (or the security boundary: tenant, role) whenever
> what a query returns depends on who is asking.

```elixir
# Wrong when masking or a before_query rewrite depends on the actor:
Lotus.run_query(query, context: %{actor: current_user})

# Right — the actor is part of the cache identity and reaches the resolver:
Lotus.run_query(query,
  context: %{request_id: request_id},
  scope: %{tenant_id: current_user.tenant_id, role: current_user.role}
)
```

Use the narrowest scope that captures the security boundary. A scope of `%{user_id: id}` gives every user their own cache entry, which is correct but has a low hit rate; `%{tenant_id: id, role: role}` is usually the right granularity when masking is decided by tenant and role.

The same rule applies to discovery: `Lotus.list_tables/2`, `describe_table/3` and friends pass `:scope` to the visibility resolver *and* hash it into the discovery key, so a resolver that hides tables per tenant does not leak one tenant's table list into another's.

### Custom Key Builder

The key scheme can be replaced by implementing the `Lotus.Cache.KeyBuilder` behaviour. This is useful when you need extra components in the key or a different hashing strategy.

```elixir
defmodule MyApp.CustomKeyBuilder do
  @behaviour Lotus.Cache.KeyBuilder

  @impl true
  def discovery_key(params, scope) do
    # Add the deployment environment to discovery keys
    env = Application.get_env(:my_app, :env, :prod)

    Lotus.Cache.KeyBuilder.Default.discovery_key(
      %{params | components: Tuple.append(params.components, env)},
      scope
    )
  end

  @impl true
  def result_key(body, bound, opts, scope) do
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

- `discovery_key/2` — keys for schema introspection entries. Takes a map with `:kind` (e.g. `:list_schemas`, `:list_tables`), `:source_name`, `:components` (a tuple of kind-specific parts) and `:version`, plus the scope (or `nil`)
- `result_key/4` — keys for query result entries. Takes the statement body (`term()` — a SQL string for Ecto adapters, a JSON or AST payload for others), the bound values (map or list), an options keyword list carrying `:data_source`, `:search_path` and `:lotus_version`, and the scope (or `nil`)

`Lotus.Cache.KeyBuilder.scope_digest/1` is a public helper: it returns a 16-character hex digest of any term, and `""` for `nil`. Use it if your implementation builds its own scope-specific keys or tags.

```elixir
Lotus.Cache.KeyBuilder.scope_digest(nil)
# ""

Lotus.Cache.KeyBuilder.scope_digest(%{tenant_id: 42})
# a 16-character lowercase hex digest of the term
```

When no `key_builder` is configured, `Lotus.Cache.KeyBuilder.Default` is used.

> ### Warning {: .warning}
>
> A custom key builder that ignores its `scope` argument removes the
> per-scope isolation described above. If you delegate, delegate the scope
> too.

## Schema Function Caching

All Lotus schema introspection functions are cached automatically:

- `Lotus.list_schemas/2` — lists schemas (namespaces) in the source
- `Lotus.list_tables/2` — lists tables and views
- `Lotus.describe_table/3` — column information for a table
- `Lotus.get_table_stats/3` — row counts and table statistics
- `Lotus.list_relations/2` — tables with schema information

### Default Cache Behavior

```elixir
# Schema metadata - uses the :schema profile (1 hour TTL)
{:ok, schemas} = Lotus.list_schemas("postgres")
{:ok, tables} = Lotus.list_tables("postgres")
{:ok, columns} = Lotus.describe_table("postgres", "users")
{:ok, relations} = Lotus.list_relations("postgres")

# Table statistics - uses the :results profile (60 second TTL)
{:ok, stats} = Lotus.get_table_stats("postgres", "users")
```

**Why different profiles?**

- **Schema metadata** (tables, columns) changes rarely, so longer caching is safe
- **Table statistics** (row counts) change constantly, so a short TTL keeps them useful

### Schema Cache Options

Schema functions support all cache modes and options:

```elixir
# Bypass cache for fresh data
{:ok, tables} = Lotus.list_tables("postgres", cache: :bypass)

# Refresh cache with latest data
{:ok, columns} = Lotus.describe_table("postgres", "users", cache: :refresh)

# Use a different profile
{:ok, stats} = Lotus.get_table_stats("postgres", "users", cache: [profile: :options])

# Override TTL
{:ok, relations} = Lotus.list_relations("postgres", cache: [ttl_ms: 600_000])

# Add tags for invalidation
{:ok, columns} = Lotus.describe_table("postgres", "products",
  cache: [tags: ["metadata"]])
```

### Schema Cache Invalidation

Discovery entries are tagged automatically, so you can clear exactly what changed:

```elixir
# After schema changes (migrations, table creation, etc.)
Lotus.Cache.invalidate_tags(["source:postgres", "schema:list_tables"])

# After specific table changes
Lotus.Cache.invalidate_tags(["table:public.users"])
```

**Automatic tags on discovery entries:**

- `"source:#{source_name}"` — every entry for one data source
- `"schema:#{kind}"` — one discovery operation: `schema:list_schemas`, `schema:list_tables`, `schema:describe_table`, `schema:get_table_stats`, `schema:list_relations`, `schema:resolve_table_namespace`
- `"table:#{schema}.#{table}"` — table-specific entries (`describe_table`, `get_table_stats`, `resolve_table_namespace`); the schema part is omitted for schema-less sources
- `"scope:<digest>"` — added when a non-nil `:scope` option is passed

> ### Renamed in v1.0 {: .warning}
>
> The source tag prefix was `"repo:"` before v1.0 and is now `"source:"`.
> Host code that invalidates by tag must be updated. Entries written by a
> pre-v1 install are never found again after the upgrade; they expire on
> their own and re-seed on the next read, so this is a cold cache, not a
> correctness problem.

### Per-Scope Cache Invalidation

When you pass `:scope` to a discovery or execution function, the entry is tagged with a scope digest. That lets you clear everything for one scope without flushing the cache:

```elixir
# Populate cache for different scopes
{:ok, _} = Lotus.list_tables("postgres", scope: %{tenant_id: 1})
{:ok, _} = Lotus.list_tables("postgres", scope: %{tenant_id: 2})

# Invalidate only tenant 1's cached entries
:ok = Lotus.invalidate_scope(%{tenant_id: 1})

# Tenant 2's cache is untouched — this is still a cache hit
{:ok, _} = Lotus.list_tables("postgres", scope: %{tenant_id: 2})
```

This is what you want when visibility rules change for one scope — a tenant's permissions are updated, a role gains a table — and stale entries for that scope must go. `Lotus.invalidate_scope/1` (delegating to `Lotus.Cache.invalidate_scope/1`) clears both discovery and result entries carrying the scope tag.

`invalidate_scope/1` accepts any term and returns `:ok`. Passing `nil` is a no-op, because there is no scope tag to invalidate.

The scope must match the one used when the entry was written: the digest is taken over the term itself, so `%{tenant_id: 1}` and `%{tenant_id: "1"}` are different scopes.

## Working with run_query

Saved queries support all the same cache options:

```elixir
# Automatic caching based on configuration
{:ok, result} = Lotus.run_query(query_id)

# Bypass cache
{:ok, result} = Lotus.run_query(query_id, cache: :bypass)

# Use a specific profile
{:ok, result} = Lotus.run_query(query_id, cache: [profile: :reports])

# Tag for invalidation
{:ok, result} = Lotus.run_query(query_id, cache: [tags: ["dashboard"]])

# Per-tenant results
{:ok, result} = Lotus.run_query(query_id, scope: %{tenant_id: 42})
```

Query variables are part of the bound values, so the same saved query with different `vars` produces independent cache entries. So does each page of a windowed query.

## Cache Management

### Manual Cache Invalidation

```elixir
# Invalidate specific entries
Lotus.Cache.invalidate_tags(["user:123"])

# Invalidate multiple tags
Lotus.Cache.invalidate_tags(["user_data", "reports", "dashboard"])

# Invalidate every cached entry for a scope
Lotus.invalidate_scope(%{tenant_id: 42})
```

`invalidate_tags/1` is a no-op when no cache adapter is configured, or when the configured adapter does not support tag invalidation.

### Automatic Tagging

Lotus adds these tags to result entries:

- `"query:#{query_id}"` — for `run_query/2` calls on a saved query
- `"source:#{source_name}"` — the data source the statement ran against
- `"scope:#{digest}"` — when a non-nil `:scope` is passed

Discovery entries carry the tags listed under [Schema Cache Invalidation](#schema-cache-invalidation). Your own `cache: [tags: [...]]` are added on top of the automatic ones.

## Performance Considerations

### Cache Effectiveness

Cache activity is emitted as telemetry — `[:lotus, :cache, :hit]`, `[:lotus, :cache, :miss]` and `[:lotus, :cache, :put]` — so you can measure hit ratio without instrumenting call sites. See the [Telemetry Guide](telemetry.md).

### Memory Usage

ETS cache memory grows with cached data. Consider:

- **Appropriate TTLs** — don't cache data longer than it is useful
- **Selective caching** — use `:bypass` for large result sets that are not reused
- **Size limits** — oversized entries are skipped rather than stored (`max_bytes`, default 5 MB)
- **Scope granularity** — a per-user scope multiplies entries by your user count; prefer the narrowest boundary that is still correct
- **Regular cleanup** — expired ETS entries are swept by a janitor every 30 seconds

### Cache Warming

Pre-populate the cache with commonly used queries:

```elixir
# During application startup or from a scheduled job
{:ok, _} = Lotus.run_statement("SELECT * FROM lookup_tables", [], cache: :refresh)
{:ok, _} = Lotus.run_query(dashboard_query_id, cache: :refresh)
```

## Best Practices

### Profile Strategy

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.ETS,
    profiles: %{
      # Built-in profiles (customize as needed)
      results: [ttl_ms: 30_000],      # Default: 60s - fast-changing data
      options: [ttl_ms: 300_000],     # Default: 5m - reference data
      schema: [ttl_ms: 3_600_000],    # Default: 1h - schema information

      # Add custom profiles for specific use cases
      reports: [ttl_ms: 1_800_000]    # 30 minutes - business reports
    }
  }
```

**Default TTL Guidelines:**

- **`:results` (60s)** — query results, table statistics, transactional information
- **`:options` (5m)** — dropdown options, lookup tables, reference data
- **`:schema` (1h)** — database schema, table structure, metadata

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

- **Default mode**: most queries — let the cache do its job
- **`:bypass` mode**: real-time data, large one-off queries, testing
- **`:refresh` mode**: after data updates, scheduled cache warming, manual refresh

### Cache Invalidation

```elixir
# After updating user data
Lotus.Cache.invalidate_tags(["user:#{user.id}"])

# After bulk data updates
Lotus.Cache.invalidate_tags(["products", "inventory"])

# After schema changes (migrations, DDL operations)
Lotus.Cache.invalidate_tags(["source:postgres", "schema:list_tables"])

# After table-specific changes
Lotus.Cache.invalidate_tags(["table:public.users"])

# After a tenant's permissions change — clear only that tenant's entries
Lotus.invalidate_scope(%{tenant_id: tenant.id})
```

## Troubleshooting

### Cache Not Working

1. **Check configuration**: a cache adapter must be set under `config :lotus, :cache`, and the value must be a map
2. **Check the `:lotus` app is running**: Lotus's supervisor starts with the `:lotus` OTP app, so make sure it isn't excluded from `included_applications` or otherwise prevented from starting
3. **Verify identical calls**: keys come from the exact statement body, bound values, source, search path and scope — a different scope is a different entry by design
4. **Check TTL**: make sure the entry has not expired between calls
5. **Check entry size**: a result larger than `max_bytes` (5 MB default) is never stored, so it misses every time

**Common Error**: `** (ArgumentError) argument error` or `:noproc` errors usually mean the `:lotus` application failed to boot. The ETS cache GenServer is always started by the supervisor, so cache tables should be available as long as `:lotus` is running.

### Stale or Leaking Results

1. **Check `:scope` vs `:context`**: results that differ per actor must carry that actor in `:scope`. See [Scope and cache correctness](#scope-and-cache-correctness)
2. **Check a custom key builder**: an implementation that drops the `scope` argument removes per-scope isolation
3. **Check tag prefixes after upgrading**: invalidation code written for v0.x used `"repo:"`, which now matches nothing

### Memory Issues

1. **Review TTL settings**: shorter TTLs mean less memory
2. **Review scope granularity**: a per-user scope multiplies entry count
3. **Use selective caching**: don't cache large result sets unnecessarily

### Performance Issues

1. **Cache hit ratio**: a low ratio may mean the scope is too narrow or the TTL too short
2. **TTL tuning**: balance data freshness against cache effectiveness
3. **Query optimization**: caching works best on top of already-reasonable queries
