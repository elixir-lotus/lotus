# Visibility Rules

Lotus provides a comprehensive visibility system that controls which schemas and tables are accessible through the API. This system operates on two levels with clear precedence rules to ensure security while maintaining flexibility.

## Overview

The visibility system uses a **two-level hierarchy**:

1. **Schema visibility** (higher precedence)
2. **Table visibility** (lower precedence)

**Key principle**: If a schema is denied, all tables within it are automatically blocked, regardless of table-level rules.

## Database-Specific Schema Behavior

Understanding how "schemas" work across different database systems is crucial for configuring visibility rules correctly:

### PostgreSQL
- **True namespaced schemas**: Multiple schemas exist within a single database
- **Examples**: `public`, `reporting`, `analytics`, `tenant_123`
- **System schemas**: `pg_catalog`, `information_schema`, `pg_toast`, `pg_temp_*`
- **Qualified names**: `reporting.customers`, `public.users`

### MySQL
- **Schemas = Databases**: In MySQL, "schema" and "database" are synonymous
- **Examples**: `lotus_production`, `analytics_db`, `warehouse`
- **System schemas**: `mysql`, `information_schema`, `performance_schema`, `sys`
- **Behavior**: When you connect to MySQL, you can access tables across different databases/schemas
- **Qualified names**: `analytics_db.customers`, `warehouse.sales`

### SQLite
- **No schema support**: SQLite is schema-less
- **Schema visibility**: Not applicable (always empty list)
- **Tables**: Exist at the database level without namespace prefixes

## Configuration

Configure visibility rules in your application config:

```elixir
config :lotus,
  # Schema-level visibility (higher precedence)
  schema_visibility: %{
    default: [
      deny: ["restricted_schema", ~r/^temp_/],
      allow: :all  # or specific schemas
    ],
    postgres: [
      # Only allow public and tenant schemas
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
      # Data warehouse example
      allow: [
        {"public", ~r/^dim_/},      # Dimension tables
        {"public", ~r/^fact_/},     # Fact tables
        {"analytics", ~r/.*/}       # All analytics tables
      ],
      deny: [
        {"public", ~r/^staging_/},  # Block staging tables
        {"public", ~r/_temp$/}      # Block temp tables
      ]
    ]
  }
```

## Rule Syntax

### Schema Rules

Schema rules use simpler patterns since they only match schema names:

- `"exact_name"` - Matches exact schema name
- `~r/pattern/` - Regex pattern for dynamic matching
- `:all` - Special value for allow rules (allows all schemas)

**Examples**:
```elixir
allow: ["public", "reporting", ~r/^tenant_\w+$/]
deny: ["restricted", ~r/^temp_/]
```

### Table Rules

Table rules support multiple formats for maximum flexibility:

- `{"schema", "table"}` - Exact schema.table match
- `{"schema", ~r/pattern/}` - Regex table pattern in specific schema
- `{~r/schema_pattern/, "table"}` - Table in schemas matching pattern
- `"table"` - Table name in any schema (global rule)

**Examples**:
```elixir
allow: [
  {"public", "users"},           # Specific table
  {"reporting", ~r/^daily_/},    # Tables starting with "daily_" in reporting
  {~r/^tenant_/, "customers"},   # customers table in any tenant schema
  "products"                     # products table in any schema
]
```

## Precedence and Evaluation

### 1. Schema Gating (First)
```elixir
if not allowed_schema?(schema) do
  deny  # Schema denied → everything in it blocked
else
  # Schema allowed → proceed to table rules
end
```

### 2. Deny Always Wins (Second)
```elixir
if deny_rule_matches?(schema, table) do
  deny  # Any deny rule blocks access
else
  # Check allow posture
end
```

### 3. Schema-Scoped Allow Posture (Third)
For each schema, compute its "allow posture":

- **Has allow posture**: Allow rules exist that could apply to this schema
- **No allow posture**: No allow rules target this schema

```elixir
# Rules: allow: [{"restricted", "allowed_table"}]

# For "restricted" schema:
allow_posture? = true   # Has rule targeting "restricted"
# → Default-deny: only "allowed_table" allowed

# For "public" schema:
allow_posture? = false  # No rules targeting "public"
# → Default-allow: all tables allowed (unless denied)
```

## Practical Examples

### Multi-Tenant SaaS Application

```elixir
config :lotus,
  schema_visibility: %{
    postgres: [
      # Only allow public and tenant schemas
      allow: ["public", ~r/^tenant_\d+$/],
      deny: ["admin_schema", "system_logs"]
    ]
  },
  table_visibility: %{
    postgres: [
      allow: [
        {"public", ~r/^shared_/},        # Shared lookup tables
        {~r/^tenant_/, "users"},         # User table in each tenant
        {~r/^tenant_/, "orders"},        # Order table in each tenant
        {~r/^tenant_/, "products"}       # Product table in each tenant
      ],
      deny: [
        {~r/^tenant_/, "internal_logs"}, # Hide logs from all tenants
        "api_keys"                       # Hide API keys globally
      ]
    ]
  }
```

**Result**:
- ✅ `tenant_123.users` → Allowed
- ✅ `public.shared_categories` → Allowed
- ❌ `tenant_123.internal_logs` → Denied (table rule)
- ❌ `admin_schema.anything` → Denied (schema rule)

### Data Warehouse

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
        {"public", ~r/^dim_/},         # Dimension tables
        {"public", ~r/^fact_/},        # Fact tables
        {"warehouse", ~r/.*/},         # All warehouse tables
        {"analytics", ~r/^report_/}    # Only report tables in analytics
      ],
      deny: [
        {"public", ~r/^raw_/},         # Hide raw data tables
        {"warehouse", ~r/_backup$/}    # Hide backup tables
      ]
    ]
  }
```

### MySQL Multi-Database Setup

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
        {"lotus_production", ~r/^public_/},    # Only public tables from main DB
        {"analytics_warehouse", ~r/.*/},       # All analytics tables
        {"reporting_db", ~r/^report_/}         # Only reports from reporting DB
      ],
      deny: [
        "user_passwords",                      # Hide globally
        {"lotus_production", ~r/^internal_/}   # Hide internal tables
      ]
    ]
  }
```

## Testing Visibility Rules

You can test your visibility configuration using the programmatic API:

```elixir
# Test schema visibility
{:ok, schemas} = Lotus.list_schemas("postgres")
# Returns only visible schemas

# Test table visibility
{:ok, tables} = Lotus.list_tables("postgres", schema: "public")
# Returns only visible tables in public schema

# Direct visibility check
Lotus.Visibility.allowed_schema?("postgres", "restricted")
# Returns true/false

Lotus.Visibility.allowed_relation?("postgres", {"public", "users"})
# Returns true/false
```

## Error Handling

When schema visibility blocks access, you'll receive clear error messages:

```elixir
# Trying to list tables in denied schema
{:error, "Schema(s) not visible: pg_catalog, restricted"} =
  Lotus.list_tables("postgres", schemas: ["public", "pg_catalog", "restricted"])

# Validation helper
{:error, :schema_not_visible, denied: ["pg_catalog"]} =
  Lotus.Visibility.validate_schemas(["public", "pg_catalog"], "postgres")
```

## Built-in Security

Lotus automatically denies system schemas to prevent accidental exposure:

### PostgreSQL Built-ins
- `pg_catalog` - System catalog
- `information_schema` - SQL standard metadata
- `pg_toast` - TOAST storage
- `~r/^pg_temp/` - Temporary schemas
- `~r/^pg_toast/` - Additional TOAST schemas

### MySQL Built-ins
- `mysql` - MySQL system database
- `information_schema` - SQL standard metadata
- `performance_schema` - Performance monitoring
- `sys` - Diagnostic information

### All Databases
- Migration tables (e.g., `schema_migrations`)
- Lotus internal tables (e.g., `lotus_queries`)

These built-in denies always apply, even if your custom rules would allow them. This ensures security by default.

## Migration from Table-Only Rules

If you're upgrading from table-only visibility rules:

1. **Review existing rules**: Identify any schema-specific patterns
2. **Extract schema rules**: Move schema-level restrictions to `schema_visibility`
3. **Test thoroughly**: Schema rules take precedence and can block more than expected
4. **Use validation**: Test your configuration with `Lotus.Visibility.validate_schemas/2`

## Best Practices

1. **Start restrictive**: Use allow lists for sensitive environments
2. **Layer security**: Use schema rules for broad restrictions, table rules for fine-tuning
3. **Test configurations**: Use the programmatic API to verify your rules work as expected
4. **Document your rules**: Complex visibility configurations should be documented for your team
5. **Consider performance**: Schema-level filtering is more efficient than table-level
6. **MySQL considerations**: Remember that schemas = databases in MySQL
7. **Regex careful**: Test regex patterns thoroughly to avoid unintended matches

## Common Patterns

### Development vs Production

```elixir
# Development - more permissive
config :lotus,
  schema_visibility: %{
    default: [allow: :all, deny: ["dangerous_schema"]]
  }

# Production - restrictive allowlist
config :lotus,
  schema_visibility: %{
    default: [
      allow: ["public", "reporting"],
      deny: []  # not needed with restrictive allow
    ]
  }
```

### Dynamic tenant schemas

```elixir
config :lotus,
  schema_visibility: %{
    postgres: [
      allow: ["public", ~r/^tenant_[a-f0-9]{8}$/],  # UUID-based tenants
      deny: []
    ]
  }
```

### Supabase Configuration

When using Supabase as your database, it includes many additional system schemas that you typically don't want your users to query directly through Lotus. It's recommended to configure Lotus with schema deny rules to hide these internal schemas:

```elixir
config :lotus,
  schema_visibility: %{
    default: [
      deny: [
        "auth",           # Supabase authentication
        "extensions",     # PostgreSQL extensions
        "graphql",        # GraphQL schema
        "graphql_public", # Public GraphQL schema
        "pgbouncer",      # Connection pooler
        "realtime",       # Realtime subscriptions
        "storage",        # File storage
        "vault",          # Secrets management
        "pg_catalog",     # PostgreSQL system catalog
        "information_schema", # SQL standard metadata
        "pg_toast"        # TOAST storage
      ]
    ]
  }
```

This configuration ensures that:
- Users can only query your application's schemas (like `public`)
- Supabase's internal schemas remain hidden from the Lotus interface
- System schemas are properly protected from accidental exposure

**Note**: The last three schemas (`pg_catalog`, `information_schema`, `pg_toast`) are already blocked by Lotus's built-in security, but including them explicitly in your configuration makes the intent clear.

## Column-Level Visibility

Column visibility provides fine-grained control over individual columns within tables. You can hide sensitive data, mask personally identifiable information (PII), or prevent certain columns from being queried entirely.

### Configuration

Add column visibility rules to your configuration:

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

Column policies support four actions:

- **`:allow`** - Show column values normally (default behavior)
- **`:omit`** - Remove column entirely from query results
- **`:mask`** - Transform/redact column values using a masking strategy
- **`:error`** - Fail the query if this column is selected

### Masking Strategies

When using `:mask` action, choose from these strategies:

#### `:null` - Replace with NULL
```elixir
{"users", "middle_name", [action: :mask, mask: :null]}
```

#### `:sha256` - Replace with SHA256 hash
```elixir
{"users", "ssn", [action: :mask, mask: :sha256]}
# "123-45-6789" becomes "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3"
```

#### `{:fixed, value}` - Replace with fixed value
```elixir
{"users", "salary", [action: :mask, mask: {:fixed, "CONFIDENTIAL"}]}
```

#### `{:partial, options}` - Partial masking
```elixir
# Keep last 4 characters, mask the rest
{"users", "phone", [action: :mask, mask: {:partial, keep_last: 4}]}
# "555-123-4567" becomes "*******4567"

# Keep first 2 and last 4, custom replacement
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

### Schema Introspection Control

Control whether columns appear in schema introspection:

```elixir
column_visibility: %{
  default: [
    # Column is masked but visible in schema
    {"password_hash", [action: :mask, mask: :sha256, show_in_schema?: true]},

    # Column is omitted and hidden from schema
    {"internal_notes", [action: :omit, show_in_schema?: false]}
  ]
}
```

### Pattern Matching

Use regex patterns for flexible column matching:

```elixir
column_visibility: %{
  postgres: [
    # Hide all columns ending in _secret
    {~r/_secret$/, :error},

    # Mask all PII columns across specific tables
    {"users", ~r/(ssn|phone|email)/, [action: :mask, mask: :sha256]},

    # Hash all audit columns in analytics schema
    {"analytics", ~r/.*/, ~r/^audit_/, [action: :mask, mask: :sha256]}
  ]
}
```

### Simple Syntax

For common cases, use atom shortcuts:

```elixir
column_visibility: %{
  default: [
    {"password", :error},        # Same as [action: :error]
    {"temp_data", :omit},        # Same as [action: :omit]
    {"user_agent", :mask}        # Same as [action: :mask, mask: :null]
  ]
}
```

### Precedence Rules

Column rules are evaluated in this order (most to least specific):

1. **Schema + Table + Column** - `{"public", "users", "email", policy}`
2. **Table + Column** - `{"users", "email", policy}`
3. **Column Only** - `{"email", policy}`

The most specific matching rule wins.

### Examples

#### PII Protection
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

#### Development vs Production
```elixir
# Different rules per environment
column_visibility: %{
  default: [
    {"password", if(Mix.env() == :prod, do: :error, else: :allow)},
    {"debug_info", if(Mix.env() == :prod, do: :omit, else: :allow)}
  ]
}
```

#### Multi-tenant Data
```elixir
column_visibility: %{
  postgres: [
    # Hide tenant isolation columns
    {~r/^tenant_\d+/, ~r/.*/, "tenant_id", :omit},

    # Mask cross-tenant data
    {"shared_data", "user_reference", [action: :mask, mask: :sha256]}
  ]
}
```
