# Schema Introspection

Lotus can explore the structure of every configured data source: its
namespaces, its tables and views, the columns of a table, and basic
statistics. This guide covers the discovery API, the options every
discovery call accepts, and how visibility, caching and middleware apply
to the results.

## A note on the word "schema"

In Lotus v1 **"schema" always means namespace** — a PostgreSQL schema, a
MySQL database, a BigQuery dataset. The structure of a table (its
columns, types and constraints) is called **columns**, and the function
that returns it is `Lotus.describe_table/3`.

Pre-v1 code that called `Lotus.get_table_schema` must call
`Lotus.describe_table/3` instead. There is no alias — the old name is
gone.

## The discovery API

`Lotus.Schema` holds the implementation; `Lotus` delegates to it, and the
`Lotus.*` names are the ones to use.

| Function | Returns |
| --- | --- |
| `Lotus.list_schemas/2` | visible namespace names, `[String.t()]` |
| `Lotus.list_tables/2` | `{schema, table}` tuples, or plain table names for a schema-less source |
| `Lotus.list_relations/2` | always `{schema \| nil, table}` tuples |
| `Lotus.describe_table/3` | column definitions for one table |
| `Lotus.get_table_stats/3` | a stats map, at minimum `%{row_count: n}` |

Every one of them applies the configured visibility rules before
returning. See the [Visibility guide](visibility.md).

The first argument is a configured source: its name (`"postgres"`) or,
for Ecto-backed sources, the repo module (`MyApp.ReportingRepo`).

```elixir
{:ok, tables} = Lotus.list_tables("postgres")
{:ok, tables} = Lotus.list_tables(MyApp.ReportingRepo)
```

An unknown source raises rather than returning an error tuple:

```elixir
Lotus.list_tables("nonexistent")
# ** (ArgumentError) Data source "nonexistent" not configured.
#    Available sources: ["postgres", "sqlite"]
```

## Relations are two-level

Lotus names every resource with exactly two levels: `{schema | nil,
table}`. Visibility rules, deny lists, `describe_table/3`, the preflight
relation set — all of them speak that shape, and core never grows a third
element.

`nil` in the first position means "unqualified": a source with no
namespace concept at all (SQLite tables, Elasticsearch indices), or a
name the caller left unqualified.

An engine with a **deeper** hierarchy flattens everything above the leaf
into the schema part, keeping its own separator:

- BigQuery `project.dataset.table` → `{"project.dataset", "table"}`
- A catalog/schema/table engine → `{"catalog.schema", "table"}`

The adapter owns that flattening. Core compares the schema part verbatim
against your visibility rules, so a deny rule must be written in the
flattened spelling the adapter emits.

## Listing schemas

```elixir
{:ok, schemas} = Lotus.list_schemas("postgres")
# ["public", "reporting", "analytics"]

{:ok, schemas} = Lotus.list_schemas("mysql")
# ["app_production", "analytics_db"]   (in MySQL, schemas are databases)

{:ok, schemas} = Lotus.list_schemas("sqlite")
# []                                   (SQLite has no namespaces)
```

System schemas (`pg_catalog`, `information_schema`, ...) are always
filtered out.

## Listing tables

```elixir
# Default namespaces for the source
{:ok, tables} = Lotus.list_tables("postgres")
# [{"public", "users"}, {"public", "posts"}]

# A schema-less source returns plain strings
{:ok, tables} = Lotus.list_tables("sqlite")
# ["products", "orders", "order_items"]
```

### Choosing namespaces

```elixir
# One schema
{:ok, tables} = Lotus.list_tables("postgres", schema: "reporting")

# Several schemas
{:ok, tables} = Lotus.list_tables("postgres", schemas: ["reporting", "analytics"])

# A PostgreSQL-style search_path string
{:ok, tables} = Lotus.list_tables("postgres", search_path: "reporting, analytics, public")
```

`:schema`, `:schemas` and `:search_path` are checked in that order; the
first one present wins. When none is given, the adapter's default
namespaces are used. Entries that are blank or `$user` are dropped.

Requesting a namespace that visibility denies fails the whole call:

```elixir
Lotus.list_tables("postgres", schemas: ["public", "pg_catalog"])
# {:error, "Schema(s) not visible: pg_catalog"}
```

### Including views

```elixir
{:ok, relations} = Lotus.list_tables("postgres",
  search_path: "reporting, public",
  include_views: true
)
```

Views are excluded by default.

## Describing a table

`Lotus.describe_table/3` returns the column definitions of one table.

```elixir
{:ok, columns} = Lotus.describe_table("postgres", "users")

# Each entry:
# %{
#   name: "id",
#   type: "bigint",
#   nullable: false,
#   default: "nextval('users_id_seq'::regclass)",
#   primary_key: true
# }

Enum.each(columns, fn col ->
  IO.puts("#{col.name}: #{col.type}#{if col.nullable, do: "", else: " NOT NULL"}")
end)
```

The table is located the same way as in `list_tables/2` — `:schema`,
`:schemas` or `:search_path`, first match wins:

```elixir
{:ok, columns} = Lotus.describe_table("postgres", "customers", schema: "reporting")

{:ok, columns} = Lotus.describe_table("postgres", "revenue",
  search_path: "reporting, analytics, public"
)
```

Working with the result is plain list handling:

```elixir
{:ok, columns} = Lotus.describe_table("postgres", "products")

price = Enum.find(columns, &(&1.name == "price"))
primary_keys = Enum.filter(columns, & &1.primary_key)
nullable = Enum.filter(columns, & &1.nullable)
```

SQLite reports the same map shape with its own type spellings:

```elixir
{:ok, columns} = Lotus.describe_table("sqlite", "products")
# %{name: "id", type: "INTEGER", nullable: true, default: nil, primary_key: true}
```

### Column visibility in the result

Column rules (see the [Visibility guide](visibility.md)) are applied to
the description too:

- a column whose policy sets `show_in_schema?: false` is **removed** from
  the list entirely;
- a column with any other non-`nil` policy gains a `:visibility` key
  holding `%{action: ..., mask: ...}`, so a UI can label it as masked or
  blocked before anyone runs a query.

```elixir
{:ok, columns} = Lotus.describe_table("postgres", "users")

Enum.find(columns, &(&1.name == "ssn"))
# %{name: "ssn", type: "text", ..., visibility: %{action: :mask, mask: :sha256}}
```

## Table statistics

```elixir
{:ok, stats} = Lotus.get_table_stats("postgres", "users")
# %{row_count: 1234}

{:ok, stats} = Lotus.get_table_stats("postgres", "customers", schema: "reporting")
```

Lotus asks the adapter first. A source whose adapter implements the
optional `c:Lotus.Source.Adapter.table_stats/3` callback answers from
that callback and may return extra keys alongside `:row_count` (on-disk
size, segment counts, a last-analyzed timestamp) — callers should
tolerate extras. An adapter that does not implement it falls back to
`SELECT COUNT(*)` against the quoted relation, which only makes sense for
SQL sources.

Unlike the other discovery calls, `get_table_stats/3` fires no middleware
events. It accepts `:schema`, `:schemas`, `:search_path`, `:cache` and
`:scope`.

## Listing relations

`Lotus.list_relations/2` is `list_tables/2` that always keeps the
namespace, which is what a table picker in a UI usually wants:

```elixir
{:ok, relations} = Lotus.list_relations("postgres", search_path: "reporting, public")
# [{"reporting", "customers"}, {"public", "users"}, ...]

{:ok, relations} = Lotus.list_relations("sqlite")
# [{nil, "products"}, {nil, "orders"}, ...]
```

It takes the same `:schema` / `:schemas` / `:search_path` /
`:include_views` options as `list_tables/2`.

## `:scope` and `:context`

`list_schemas/2`, `list_tables/2`, `list_relations/2` and
`describe_table/3` all accept two opaque caller-supplied values. They do
different jobs:

- **`:scope`** is handed to the visibility resolver
  (`c:Lotus.Visibility.Resolver.table_rules_for/2` and friends receive
  `(source_name, scope)`) and is hashed into the cache key. Different
  scopes therefore produce independent cached entries.
- **`:context`** is threaded into the middleware payloads only. It never
  reaches the resolver and never changes the cache key.

```elixir
# Per-role rules, cached separately per role
{:ok, tables} = Lotus.list_tables("postgres", scope: %{role: :admin})

# Per-tenant middleware filtering, shared cache
{:ok, tables} = Lotus.list_tables("postgres", context: %{tenant: "acme"})
```

Keep scope low-cardinality (per-role, per-tenant) so the cache still
hits. A resolver that reads runtime context — the process dictionary,
say — instead of using its `scope` argument will cache incorrectly; put
context-dependent logic in middleware, or pass it as scope.

Scoped rules are not only a discovery concern. As of v1 they are enforced
at execution time as well: `Lotus.Preflight.authorize/4` takes the scope,
and `Lotus.Runner` passes the `:scope` option through to it. See
[Visibility](visibility.md#scoped-rules-are-enforced-at-execution-time).

Cached entries for one scope can be dropped on their own:

```elixir
:ok = Lotus.invalidate_scope(%{role: :admin})
```

## Middleware events

Every discovery call fires two events (see `Lotus.Middleware`):

1. the kind-specific event, with a kind-specific payload;
2. the unified `:after_discover` event, with
   `%{kind:, source:, result:, scope:, context:}`.

| Call | Kind-specific event | Payload keys |
| --- | --- | --- |
| `list_schemas/2` | `:after_list_schemas` | `:schemas`, `:source`, `:scope`, `:context` |
| `list_tables/2` | `:after_list_tables` | `:tables`, `:source`, `:scope`, `:context` |
| `describe_table/3` | `:after_describe_table` | `:columns`, `:table_name`, `:schema`, `:source`, `:scope`, `:context` |
| `list_relations/2` | `:after_list_relations` | `:relations`, `:source`, `:scope`, `:context` |

Two v1 changes to note: the event formerly called
`:after_get_table_schema` is now `:after_describe_table`, and the payload
key formerly called `:repo` is now `:source`.

Both events run **outside** the cache callback, so only the raw,
visibility-filtered adapter result is cached. Context-sensitive
middleware is therefore safe to use without poisoning the cache, at the
cost of running the middleware pipeline on every call.

## Caching

Discovery results are cached by Lotus itself when a cache adapter is
configured — there is no need to build your own layer. The default
profile is `:schema` for the listing and description calls and `:results`
for `get_table_stats/3`.

```elixir
# Use the configured cache (default)
{:ok, tables} = Lotus.list_tables("postgres")

# Custom profile or TTL
{:ok, tables} = Lotus.list_tables("postgres", cache: [profile: :schema, ttl_ms: 300_000])

# Skip the cache for this call
{:ok, tables} = Lotus.list_tables("postgres", cache: :bypass)

# Run the call and overwrite the cached entry
{:ok, tables} = Lotus.list_tables("postgres", cache: :refresh)
```

Entries are tagged `"source:<name>"` and `"schema:<kind>"` (plus
`"scope:<digest>"` when a scope is given), so they can be invalidated by
tag. See the [Caching guide](caching.md).

## Error handling

```elixir
# Table not found in the searched namespaces
{:error, msg} = Lotus.describe_table("postgres", "nonexistent")
# "Table 'nonexistent' not found in schemas: public"

{:error, msg} = Lotus.describe_table("postgres", "users", schema: "reporting")
# "Table 'users' not found in schemas: reporting"

# Table blocked by visibility rules
{:error, msg} = Lotus.describe_table("postgres", "api_keys")
# "Table 'public.api_keys' is not visible by Lotus policy"

# Namespace blocked by visibility rules
{:error, msg} = Lotus.list_tables("postgres", schemas: ["public", "restricted"])
# "Schema(s) not visible: restricted"
```

A source name that is not configured raises `ArgumentError` — it is a
configuration mistake, not a runtime condition.

## Multi-tenant patterns

### Schema-per-tenant

```elixir
defmodule MyApp.TenantInspector do
  def list_tenant_tables(tenant_id) do
    Lotus.list_tables("postgres", schema: "tenant_#{tenant_id}")
  end

  def tenant_table_info(tenant_id, table_name) do
    schema = "tenant_#{tenant_id}"

    with {:ok, columns} <- Lotus.describe_table("postgres", table_name, schema: schema),
         {:ok, stats} <- Lotus.get_table_stats("postgres", table_name, schema: schema) do
      {:ok, %{columns: columns, row_count: stats.row_count}}
    end
  end
end
```

### Tenant-scoped visibility

When the rules themselves differ per tenant, pass `:scope` so the
resolver sees the tenant and the cache keeps the results apart:

```elixir
{:ok, tables} = Lotus.list_tables("postgres", scope: %{tenant_id: 42})
{:ok, result} = Lotus.run_query(query, scope: %{tenant_id: 42})
```

Pass the same scope to execution. Without it, a table hidden from a
tenant in the explorer would still return its rows from a query.

## Building admin tools

```elixir
defmodule MyApp.AdminDashboard do
  def database_overview(source) do
    {:ok, relations} =
      Lotus.list_relations(source,
        search_path: "reporting, analytics, public",
        include_views: true
      )

    relations
    |> Enum.map(fn {schema, table} ->
      {:ok, stats} = Lotus.get_table_stats(source, table, schema: schema)
      %{schema: schema, table: table, row_count: stats.row_count}
    end)
    |> Enum.sort_by(& &1.row_count, :desc)
  end

  def table_details(source, schema, table) do
    with {:ok, columns} <- Lotus.describe_table(source, table, schema: schema),
         {:ok, stats} <- Lotus.get_table_stats(source, table, schema: schema) do
      %{
        name: table,
        schema: schema,
        columns: columns,
        column_count: length(columns),
        row_count: stats.row_count,
        primary_keys: columns |> Enum.filter(& &1.primary_key) |> Enum.map(& &1.name)
      }
    end
  end
end
```

`list_relations/2` is the right call here: it keeps the namespace for
every source, so the same code works against PostgreSQL and SQLite.

## Introspection and query building

Use discovery to check a table before writing a query against it:

```elixir
defmodule MyApp.QueryBuilder do
  def build_count_query(source, schema, table) do
    case Lotus.describe_table(source, table, schema: schema) do
      {:ok, _columns} ->
        statement =
          if schema,
            do: "SELECT COUNT(*) AS total FROM #{schema}.#{table}",
            else: "SELECT COUNT(*) AS total FROM #{table}"

        Lotus.create_query(%{
          name: "Count #{schema}.#{table}",
          statement: statement,
          data_source: source,
          search_path: schema
        })

      {:error, reason} ->
        {:error, "Cannot create query: #{reason}"}
    end
  end
end
```

Never interpolate a user-supplied table name into a statement. Resolve it
through `list_relations/2` first and use the value Lotus returned, so a
name that visibility denies never reaches the SQL.

An ad-hoc check runs through `Lotus.run_statement/3` (renamed from
`run_sql/3` in v1):

```elixir
def preview(source, schema, table) do
  with {:ok, _columns} <- Lotus.describe_table(source, table, schema: schema),
       {:ok, result} <-
         Lotus.run_statement("SELECT * FROM #{schema}.#{table} LIMIT 10", [], repo: source) do
    {:ok, result}
  end
end
```

## Best practices

### Name the namespace when you know it

```elixir
# Precise
{:ok, tables} = Lotus.list_tables("postgres", schema: "reporting")

# Broader, and slower on a database with many schemas
{:ok, tables} = Lotus.list_tables("postgres", search_path: "reporting, analytics, public")
```

### Prefer `list_relations/2` for code that must work everywhere

`list_tables/2` collapses to plain strings when every relation is
unqualified, which means the caller has two shapes to handle.
`list_relations/2` always returns `{schema | nil, table}`.

### Let visibility do the filtering

Discovery already applies the rules. Configure them once instead of
filtering the results by hand:

```elixir
config :lotus,
  table_visibility: %{
    default: [
      # Bare strings match the table name in any namespace
      deny: ["api_keys", "user_passwords", "audit_logs"]
    ],
    reporting: [
      allow: [
        {"reporting", ~r/.*/},
        {"public", "users"},
        "summaries"
      ]
    ]
  }
```

## Next steps

- [Visibility](visibility.md) — schema, table and column rules, scopes and preflight
- [Caching](caching.md) — profiles, TTLs and tag invalidation
- [Middleware](middleware.md) — the discovery events in full
- [Source adapters](source-adapters.md) — implementing introspection for a new engine
