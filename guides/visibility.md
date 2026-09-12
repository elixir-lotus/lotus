# Visibility Rules

Lotus decides what a query and an explorer are allowed to see with one
rule set, applied at three levels: **schemas** (namespaces), **tables**
and **columns**. The levels have a clear precedence, so security holds by
default while leaving room for fine-grained exceptions.

## Overview

1. **Schema visibility** — highest precedence. A denied schema blocks
   every table in it, whatever the table rules say.
2. **Table visibility** — checked only inside allowed schemas.
3. **Column visibility** — applied to the columns of a result set and to
   the output of `Lotus.describe_table/3`.

Rules are enforced in three places:

- **Discovery** — `Lotus.list_schemas/2`, `list_tables/2`,
  `list_relations/2`, `describe_table/3` and `get_table_stats/3` filter
  their results.
- **Execution preflight** — before a statement runs, Lotus asks the
  adapter which relations the statement touches and blocks the query if
  any of them is denied. This catches access through views and
  subqueries.
- **Result columns** — column policies omit, mask or reject columns in
  the returned rows.

## Database-Specific Schema Behavior

"Schema" means namespace throughout Lotus, and namespaces differ per
engine:

### PostgreSQL
- **True namespaced schemas**: several schemas inside one database
- **Examples**: `public`, `reporting`, `analytics`, `tenant_123`
- **System schemas**: `pg_catalog`, `information_schema`, `pg_toast`, `pg_temp_*`
- **Qualified names**: `reporting.customers`, `public.users`

### MySQL
- **Schemas = databases**: the two words mean the same thing
- **Examples**: `lotus_production`, `analytics_db`, `warehouse`
- **System schemas**: `mysql`, `information_schema`, `performance_schema`, `sys`
- **Qualified names**: `analytics_db.customers`, `warehouse.sales`

### SQLite
- **No namespaces**: `Lotus.list_schemas/2` returns `[]`
- Relations are `{nil, table}`; schema rules do not apply

### Engines with a deeper hierarchy

Lotus names every resource as exactly two levels, `{schema | nil,
table}`. An adapter for an engine with more levels flattens everything
above the leaf into the schema part, keeping its own separator — BigQuery
`project.dataset.table` becomes `{"project.dataset", "table"}`. Core
compares that string verbatim, so write your rules in the flattened
spelling the adapter emits.

## Configuration

Visibility rules live in your application config, keyed by data source
name (matching a key of `:data_sources`) or `:default`:

```elixir
config :lotus,
  # Schema-level visibility (higher precedence)
  schema_visibility: %{
    default: [
      deny: ["restricted_schema", ~r/^temp_/],
      allow: :all  # or a list of specific schemas
    ],
    postgres: [
      allow: ["public", ~r/^tenant_\d+$/],
      deny: ["legacy_schema"]
    ],
    mysql: [
      # In MySQL, these are database names
      allow: ["lotus_production", "analytics_warehouse"],
      deny: ["staging_db", "backup_db"]
    ]
  },

  # Table-level visibility (lower precedence)
  table_visibility: %{
    default: [
      deny: ["user_passwords", "api_keys", ~r/^audit_/],
      allow: []  # empty = allow all (except denied)
    ],
    postgres: [
      allow: [
        {"public", ~r/^dim_/},      # Dimension tables
        {"public", ~r/^fact_/},     # Fact tables
        {"analytics", ~r/.*/}       # All analytics tables
      ],
      deny: [
        {"public", ~r/^staging_/},
        {"public", ~r/_temp$/}
      ]
    ]
  }
```

The source keys are matched by name against the entries of
`:data_sources` (renamed from `:data_repos` in v1). A source with no
entry of its own falls back to `:default`.

## Rule Syntax

### Schema Rules

Schema rules match a namespace name:

- `"exact_name"` — exact match
- `~r/pattern/` — regex match
- `:all` — allow value that permits every schema

```elixir
allow: ["public", "reporting", ~r/^tenant_\w+$/]
deny: ["restricted", ~r/^temp_/]
```

### Table Rules

Table rules take several shapes:

- `{"schema", "table"}` — exact schema + table
- `{"schema", ~r/pattern/}` — table pattern inside one schema
- `{~r/schema_pattern/, "table"}` — table in every matching schema
- `{nil, "table"}` — table in a source with no namespace (SQLite)
- `"table"` — table name in any schema (global rule)

```elixir
allow: [
  {"public", "users"},           # Specific table
  {"reporting", ~r/^daily_/},    # daily_* in reporting
  {~r/^tenant_/, "customers"},   # customers in every tenant schema
  "products"                     # products in any schema
]
```

A `nil` schema pattern matches only a relation whose schema is `nil` or
`""`. That keeps SQLite-shaped rules from matching PostgreSQL relations.

## Precedence and Evaluation

### 1. Schema gating (first)

```elixir
if not allowed_schema?(source, schema) do
  deny  # Schema denied → everything in it blocked
else
  # Schema allowed → proceed to table rules
end
```

### 2. Deny always wins (second)

Any matching deny rule — built-in or your own — blocks access, even if an
allow rule also matches.

### 3. Schema-scoped allow posture (third)

Allow rules are scoped to the schemas they name, not global. For a given
schema, Lotus first collects the allow rules that could apply to it:

- **Some rules target this schema** → default-deny: the relation must
  match one of them.
- **No rule targets this schema** → default-allow: everything not denied
  is visible.

```elixir
# Rules: allow: [{"restricted", "allowed_table"}]

{"restricted", "any_table"}   # denied  — the schema has an allow posture
{"restricted", "allowed_table"} # allowed
{"public", "any_table"}       # allowed — no allow rule targets "public"
```

Bare-string rules (`"products"`) carry no schema, so they never create an
allow posture for a schema; they only widen what matches.

## Practical Examples

### Multi-tenant SaaS application

```elixir
config :lotus,
  schema_visibility: %{
    postgres: [
      allow: ["public", ~r/^tenant_\d+$/],
      deny: ["admin_schema", "system_logs"]
    ]
  },
  table_visibility: %{
    postgres: [
      allow: [
        {"public", ~r/^shared_/},        # Shared lookup tables
        {~r/^tenant_/, "users"},
        {~r/^tenant_/, "orders"},
        {~r/^tenant_/, "products"}
      ],
      deny: [
        {~r/^tenant_/, "internal_logs"},
        "api_keys"                       # Hide API keys globally
      ]
    ]
  }
```

**Result**:
- `tenant_123.users` → allowed
- `public.shared_categories` → allowed
- `tenant_123.internal_logs` → denied (table rule)
- `admin_schema.anything` → denied (schema rule)

### Data warehouse

```elixir
config :lotus,
  schema_visibility: %{
    postgres: [
      allow: ["public", "warehouse", "analytics"],
      deny: ["staging", "etl_temp"]
    ]
  },
  table_visibility: %{
    postgres: [
      allow: [
        {"public", ~r/^dim_/},
        {"public", ~r/^fact_/},
        {"warehouse", ~r/.*/},
        {"analytics", ~r/^report_/}
      ],
      deny: [
        {"public", ~r/^raw_/},
        {"warehouse", ~r/_backup$/}
      ]
    ]
  }
```

### MySQL multi-database setup

```elixir
config :lotus,
  schema_visibility: %{
    mysql: [
      # Remember: schemas = databases in MySQL
      allow: ["lotus_production", "analytics_warehouse", "reporting_db"],
      deny: ["staging_db", "backup_db", "temp_imports"]
    ]
  },
  table_visibility: %{
    mysql: [
      allow: [
        {"lotus_production", ~r/^public_/},
        {"analytics_warehouse", ~r/.*/},
        {"reporting_db", ~r/^report_/}
      ],
      deny: [
        "user_passwords",
        {"lotus_production", ~r/^internal_/}
      ]
    ]
  }
```

## Scoped Rules

Static config covers most applications. When the rules themselves depend
on who is asking — a role, a tenant, a feature flag — implement
`Lotus.Visibility.Resolver` and point the `:visibility_resolver` config
key at it:

```elixir
config :lotus, visibility_resolver: MyApp.VisibilityResolver
```

Every callback takes the source name and an opaque `scope`:

```elixir
defmodule MyApp.VisibilityResolver do
  @behaviour Lotus.Visibility.Resolver

  @impl true
  def schema_rules_for(_source_name, %{role: :admin}), do: [allow: :all]
  def schema_rules_for(_source_name, _scope), do: [allow: ["public"]]

  @impl true
  def table_rules_for(_source_name, %{tenant_id: id}),
    do: [allow: [{"tenant_#{id}", ~r/.*/}, {"public", ~r/^shared_/}]]

  def table_rules_for(source_name, _scope),
    do: Lotus.Config.rules_for_source_name(source_name)

  @impl true
  def column_rules_for(source_name, _scope),
    do: Lotus.Config.column_rules_for_source_name(source_name)
end
```

The default resolver, `Lotus.Visibility.Resolvers.Static`, ignores scope
and returns the config-based rules shown above.

Callers pass the scope with the `:scope` option:

```elixir
{:ok, tables} = Lotus.list_tables("postgres", scope: %{tenant_id: 42})
{:ok, columns} = Lotus.describe_table("postgres", "orders", scope: %{tenant_id: 42})
```

Scope is hashed into the discovery cache key, so each scope caches
independently. Keep it low-cardinality (per role, per tenant) for a
useful hit rate, and drop one scope's entries with:

```elixir
:ok = Lotus.invalidate_scope(%{tenant_id: 42})
```

A resolver that reads ambient runtime state (the process dictionary, for
example) instead of its `scope` argument will cache incorrectly: the
first caller's rules get stored under a key that ignores them. Pass the
value as scope, or move the logic into middleware.

See the [Custom Resolvers guide](custom-resolvers.md) for contracts and
testing guidance.

### Scoped rules are enforced at execution time

As of v1, scoped rules are not a discovery-only filter. Execution
preflight takes a scope too — `Lotus.Preflight.authorize/4` receives it,
and `Lotus.Runner` passes the `:scope` option straight through:

```elixir
{:ok, result} = Lotus.run_query(query, scope: %{tenant_id: 42})
{:ok, result} = Lotus.run_statement("SELECT * FROM orders", [], scope: %{tenant_id: 42})
```

**Pass the same scope to execution that you passed to discovery.** Omit
it and only the unscoped rules apply at run time: a table your resolver
hides from one tenant would disappear from the explorer while a query
still returned its rows.

## Execution Preflight

Before running a statement, Lotus asks the adapter which relations the
statement will touch, then checks each of them against the rules. For
SQL sources this uses the engine's own planner, so a denied table reached
through a view or a subquery is still caught.

`c:Lotus.Source.Adapter.extract_accessed_resources/2` returns one of
three things:

| Return | Meaning |
| --- | --- |
| `{:ok, MapSet.t({schema \| nil, table})}` | the relations the statement touches |
| `{:error, reason}` | extraction failed; the query is rejected with the formatted error |
| `{:unrestricted, reason}` | this engine cannot say statically which resources a query reads |

A blocked query returns:

```elixir
{:error, "Query touches blocked table(s): [\"public.api_keys\"]"}
```

Whether preflight runs at all is the adapter's decision, via
`c:Lotus.Source.Adapter.needs_preflight?/2`. The built-in Ecto adapter
skips it for `EXPLAIN` / `SHOW` / `PRAGMA` statements. Lotus core no
longer sniffs SQL prefixes itself.

### `{:unrestricted, reason}` and `:allow_unrestricted_resources`

Some engines cannot tell, before execution, which resources a query
reads — Elasticsearch gates access at the index level, for instance. Such
an adapter returns `{:unrestricted, reason}`.

In v0.x this was a silent `:skip`: the statement ran with no visibility
check and nothing said so. In v1 it is an explicit operator decision.
**By default, preflight blocks the statement**:

```elixir
{:error,
 "Preflight blocked: source \"elastic\" cannot enforce visibility at the adapter layer " <>
 "(index-level access control). Set `config :lotus, :allow_unrestricted_resources, true` " <>
 "or opt in per-source via `allow_unrestricted_resources: true` in the source's " <>
 "data_sources entry."}
```

Opt in globally:

```elixir
config :lotus, allow_unrestricted_resources: true
```

or — better — for the one source that needs it, in its `:data_sources`
config map:

```elixir
config :lotus,
  data_sources: %{
    "postgres" => MyApp.Repo,
    "elastic" => %{
      adapter: MyApp.ElasticAdapter,
      url: "http://localhost:9200",
      allow_unrestricted_resources: true
    }
  }
```

The per-source value wins over the global flag in both directions: a
source set to `false` stays locked down even under a permissive global
default.

Opting in means trusting that adapter — or the engine's own access
control — to enforce visibility. Lotus table rules will not apply to the
statement. Column policies still apply to the result columns, but only
the column-only rules (see below).

## Testing Visibility Rules

Check your configuration from IEx:

```elixir
# Through the discovery API
{:ok, schemas} = Lotus.list_schemas("postgres")
{:ok, tables} = Lotus.list_tables("postgres", schema: "public")

# Direct checks
Lotus.Visibility.allowed_schema?("postgres", "restricted")
# => false

Lotus.Visibility.allowed_relation?("postgres", {"public", "users"})
# => true

# With a scope
Lotus.Visibility.allowed_relation?("postgres", {"tenant_42", "orders"}, %{tenant_id: 42})

# Filter helpers
Lotus.Visibility.filter_schemas(["public", "pg_catalog"], "postgres")
# => ["public"]

Lotus.Visibility.filter_relations([{"public", "users"}, {"public", "api_keys"}], "postgres")
# => [{"public", "users"}]

# Validate requested namespaces
Lotus.Visibility.validate_schemas(["public", "pg_catalog"], "postgres")
# => {:error, :schema_not_visible, denied: ["pg_catalog"]}
```

Each of these takes an optional trailing `scope` argument, defaulting to
`nil`.

## Error Handling

```elixir
# Listing a denied namespace
{:error, "Schema(s) not visible: pg_catalog, restricted"} =
  Lotus.list_tables("postgres", schemas: ["public", "pg_catalog", "restricted"])

# Describing a denied table
{:error, "Table 'public.api_keys' is not visible by Lotus policy"} =
  Lotus.describe_table("postgres", "api_keys")

# Running a statement that touches a denied table
{:error, "Query touches blocked table(s): [\"public.api_keys\"]"} =
  Lotus.run_statement("SELECT * FROM api_keys")
```

## Built-in Security

Lotus denies its own and the engine's internals regardless of your rules.

### PostgreSQL schemas
`pg_catalog`, `information_schema`, `pg_toast`, `~r/^pg_temp/`, `~r/^pg_toast/`

### MySQL schemas
`mysql`, `information_schema`, `performance_schema`, `sys`

### Tables, every source
- the repo's migration table (`schema_migrations`, or whatever
  `:migration_source` is set to, in the repo's
  `:migration_default_prefix`)
- SQLite internals (`~r/^sqlite_/`)
- Lotus's own storage tables: `lotus_queries`,
  `lotus_query_visualizations`, `lotus_dashboards`,
  `lotus_dashboard_cards`, `lotus_dashboard_filters`,
  `lotus_dashboard_card_filter_mappings`

These denies always apply, even where your rules would allow them.

## Best Practices

1. **Start restrictive**: use allow lists in sensitive environments
2. **Layer the levels**: schema rules for broad cuts, table rules for
   fine-tuning, column rules for individual fields
3. **Test the configuration**: use the direct-check API above
4. **Pass scope everywhere**: discovery and execution, or the two
   disagree
5. **Document complex rule sets** for your team
6. **Prefer schema-level filtering**: it is cheaper than table-level
7. **MySQL**: remember that schemas are databases
8. **Test your regexes**: an over-broad pattern silently exposes tables

## Common Patterns

### Development vs production

```elixir
# Development — more permissive
config :lotus,
  schema_visibility: %{
    default: [allow: :all, deny: ["dangerous_schema"]]
  }

# Production — restrictive allowlist
config :lotus,
  schema_visibility: %{
    default: [allow: ["public", "reporting"]]
  }
```

### Dynamic tenant schemas

```elixir
config :lotus,
  schema_visibility: %{
    postgres: [
      allow: ["public", ~r/^tenant_[a-f0-9]{8}$/]  # UUID-based tenants
    ]
  }
```

### Supabase

Supabase adds many internal schemas that your users should not query
through Lotus. Deny them explicitly:

```elixir
config :lotus,
  schema_visibility: %{
    default: [
      deny: [
        "auth",           # Supabase authentication
        "extensions",     # PostgreSQL extensions
        "graphql",
        "graphql_public",
        "pgbouncer",      # Connection pooler
        "realtime",
        "storage",
        "vault",          # Secrets management
        "pg_catalog",
        "information_schema",
        "pg_toast"
      ]
    ]
  }
```

The last three are already blocked by the built-in denies; listing them
makes the intent explicit.

## Column-Level Visibility

Column visibility controls individual columns inside an allowed table:
hide sensitive fields, mask personally identifiable information, or
reject a query that selects a forbidden column.

### Configuration

```elixir
config :lotus,
  column_visibility: %{
    default: [
      # Hide sensitive columns globally
      {"password", :error},
      {"ssn", [action: :mask, mask: :sha256]},
      {"api_key", :omit}
    ],
    postgres: [
      # Schema + table + column rules (most specific)
      {"public", "users", "email", [action: :mask, mask: {:partial, keep_last: 4}]},
      {"public", "users", "credit_card", :error},

      # Table + column rules (any schema)
      {"orders", "total", [action: :mask, mask: {:fixed, "HIDDEN"}]},

      # Column rules (any schema/table)
      {"created_by", :omit},
      {"debug_info", [action: :omit, show_in_schema?: false]}
    ]
  }
```

### Actions

- **`:allow`** — show the values normally (default)
- **`:omit`** — drop the column from the result
- **`:mask`** — transform or redact the values
- **`:error`** — fail the query when the column is selected

### Masking Strategies

#### `:null` — replace with NULL
```elixir
{"users", "middle_name", [action: :mask, mask: :null]}
```

#### `:sha256` — replace with a SHA256 hash
```elixir
{"users", "ssn", [action: :mask, mask: :sha256]}
# "123-45-6789" becomes "a665a459…"
```

#### `{:fixed, value}` — replace with a constant
```elixir
{"users", "salary", [action: :mask, mask: {:fixed, "CONFIDENTIAL"}]}
```

#### `{:partial, options}` — keep the ends, mask the middle
```elixir
# Keep the last 4 characters
{"users", "phone", [action: :mask, mask: {:partial, keep_last: 4}]}
# "555-123-4567" becomes "*******4567"

# Keep the first 2 and last 4, custom replacement character
{"users", "email", [action: :mask, mask: {:partial, keep_first: 2, keep_last: 4, replacement: "#"}]}
# "john@example.com" becomes "jo#######.com"
```

Partial masking never lets a value through untouched:

```elixir
{"users", "pin", [action: :mask, mask: {:partial, keep_last: 4}]}
# "1234" becomes "****", not "1234" — a value no longer than the kept
# ends has nothing left to mask, so nothing is kept.

{"users", "key_material", [action: :mask, mask: {:partial, keep_last: 4}]}
# A binary column (`bytea`, `BLOB`, `VARBINARY`) that does not hold text
# becomes one replacement character per byte. Such data has no readable
# prefix or suffix worth keeping.
```

Values that are neither text nor binary — a `jsonb` column, for example —
are rendered the way the UI and exports render them, then masked as text.

### Builder functions

`Lotus.Visibility.Policy` builds the same policies in code:

```elixir
alias Lotus.Visibility.Policy

column_visibility: %{
  default: [
    {"ssn", Policy.column_mask(:sha256)},
    {"debug_info", Policy.column_omit(show_in_schema?: false)},
    {"password", Policy.column_error()}
  ]
}
```

### Schema introspection control

`show_in_schema?` decides whether the column appears in the output of
`Lotus.describe_table/3`:

```elixir
column_visibility: %{
  default: [
    # Masked, but still listed in the description
    {"password_hash", [action: :mask, mask: :sha256, show_in_schema?: true]},

    # Omitted and hidden from the description
    {"internal_notes", [action: :omit, show_in_schema?: false]}
  ]
}
```

A column that stays visible in the description carries its policy with
it, so a UI can label it before anyone runs a query:

```elixir
{:ok, columns} = Lotus.describe_table("postgres", "users")

Enum.find(columns, &(&1.name == "ssn"))
# %{name: "ssn", type: "text", ..., visibility: %{action: :mask, mask: :sha256}}
```

### Pattern matching

```elixir
column_visibility: %{
  postgres: [
    # Every column ending in _secret
    {~r/_secret$/, :error},

    # PII columns of the users table, in any schema
    {"users", ~r/(ssn|phone|email)/, [action: :mask, mask: :sha256]},

    # Audit columns in the analytics schema
    {"analytics", ~r/.*/, ~r/^audit_/, [action: :mask, mask: :sha256]}
  ]
}
```

`"*"` works as a wildcard wherever a pattern is accepted.

### Simple syntax

```elixir
column_visibility: %{
  default: [
    {"password", :error},        # same as [action: :error]
    {"temp_data", :omit},        # same as [action: :omit]
    {"user_agent", :mask}        # same as [action: :mask, mask: :null]
  ]
}
```

### Precedence rules

Column rules are evaluated from most to least specific:

1. **Schema + table + column** — `{"public", "users", "email", policy}`
2. **Table + column** — `{"users", "email", policy}`
3. **Column only** — `{"email", policy}`

The most specific match wins.

### Column rules and preflight

The first two forms need to know which tables the result came from.
Lotus takes that list from execution preflight, so a statement that
**skipped** preflight — an adapter whose `needs_preflight?/2` returned
`false`, or a source opted into `:allow_unrestricted_resources` — has no
relation list, and only **column-only** rules can match.

Write the rule that must always hold in the column-only form:

```elixir
column_visibility: %{
  default: [
    {"ssn", [action: :mask, mask: :sha256]}   # applies everywhere
  ],
  postgres: [
    {"public", "users", "email", :omit}       # needs preflight relations
  ]
}
```

### Examples

#### PII protection
```elixir
column_visibility: %{
  default: [
    {"ssn", [action: :mask, mask: :sha256]},
    {"credit_card", :error},
    {"phone", [action: :mask, mask: {:partial, keep_last: 4}]},
    {"email", [action: :mask, mask: {:partial, keep_first: 2, keep_last: 8}]}
  ]
}
```

#### Development vs production
```elixir
column_visibility: %{
  default: [
    {"password", if(Mix.env() == :prod, do: :error, else: :allow)},
    {"debug_info", if(Mix.env() == :prod, do: :omit, else: :allow)}
  ]
}
```

#### Multi-tenant data
```elixir
column_visibility: %{
  postgres: [
    # Hide tenant isolation columns
    {~r/^tenant_\d+/, ~r/.*/, "tenant_id", :omit},

    # Mask cross-tenant references
    {"shared_data", "user_reference", [action: :mask, mask: :sha256]}
  ]
}
```

## Next Steps

- [Schema Introspection](schema-introspection.md) — the discovery API these rules filter
- [Custom Resolvers](custom-resolvers.md) — scoped and dynamic rule sources
- [Configuration](configuration.md) — every config key in one place
