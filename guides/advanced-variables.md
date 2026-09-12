# Advanced Variables

This guide covers advanced variable usage patterns in Lotus queries: the `{{var}}` and `[[...]]` template syntax, variable definitions, automatic type casting, and — for Ecto-backed sources — the SQL transformer.

## How a Query Is Compiled

`Lotus.Storage.Query.compile/2` turns a stored query and a map of supplied
values into an executable `%Lotus.Query.Statement{}`:

```elixir
{:ok, statement} = Lotus.Storage.Query.compile(query, %{"status" => "active"})

statement.body    #=> the adapter-native payload (SQL text for Ecto sources)
statement.params  #=> the bound values
```

`compile!/2` is the raising variant. `Lotus.run_query/2` calls `compile/2`
for you, so you rarely call it directly.

The steps, in order:

1. `[[...]]` optional blocks are resolved against the supplied values
2. The adapter rewrites the raw statement (`transform_statement/2`)
3. Variable names are extracted in the order they appear
4. Each value is cast, then folded through the adapter's
   `substitute_variable/5` (or `substitute_list_variable/5`)

Step 4 is where v1 differs most from earlier versions: **substitution is
adapter-owned.** A prepared-statement adapter appends a placeholder to the
body and pushes the value onto `params`; a JSON or DSL adapter inlines the
value as a properly escaped literal in its own encoder. An adapter with no
`{{var}}` model at all returns `{:error, :unsupported}`. You write
`{{name}}` either way.

> Before v1.0 this function was `Lotus.Storage.Query.to_sql_params` and
> returned an `{sql, params}` tuple. See the
> [upgrade guide](upgrading-to-v1.md).

## Variable Definitions

Each entry in a query's `:variables` list is a `Lotus.Storage.QueryVariable`:

| Field | Values | Notes |
|---|---|---|
| `:name` | string | Required. Matches `{{name}}` in the statement |
| `:type` | `:text`, `:number`, `:date` | Required. How the value is interpreted |
| `:widget` | `:input`, `:select` | Defaults to `:input` |
| `:label` | string | Human-friendly label for the UI |
| `:default` | string | Used when no value is supplied. For `list: true`, a comma-separated string |
| `:list` | boolean | Defaults to `false`. `true` accepts multiple values |
| `:static_options` | list | Allowed values for a `:select` widget |
| `:options_query` | string | Query returning `value` and `label` columns, for a dynamic `:select` |

Those three types and two widgets are the complete set. A `:select` widget
must define either `:static_options` or `:options_query`, or the changeset
fails with `"select must define either static_options or options_query"`.

`:static_options` accepts a list of strings or a list of `{value, label}`
tuples (or maps), but the formats cannot be mixed within one variable.

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Orders by Status",
  statement: "SELECT * FROM orders WHERE status = {{status}}",
  variables: [
    %{
      name: "status",
      type: :text,
      widget: :select,
      label: "Order Status",
      default: "pending",
      static_options: [{"pending", "Pending"}, {"shipped", "Shipped"}]
    }
  ]
})
```

## Optional Variables (`[[...]]` Syntax)

Lotus supports optional variable clauses using double-bracket syntax. Clauses wrapped in `[[...]]` are automatically removed from the query when the enclosed variables have no value (missing, `nil`, or empty string `""`). When all variables inside a block have values, the brackets are stripped and the clause is kept.

This is useful for building flexible queries where some filters are optional — users can leave them blank without breaking the query.

### Basic Usage

Use `WHERE 1=1` as a base condition so that optional `[[AND ...]]` clauses can be safely removed:

```sql
SELECT * FROM users
WHERE 1=1
  [[AND "name" ILIKE '%' || {{name}} || '%']]
  [[AND "status" = {{status}}]]
ORDER BY created_at DESC
```

- If `name` is blank and `status` is `"active"`, the query becomes:
  ```sql
  SELECT * FROM users WHERE 1=1 AND "status" = $1 ORDER BY created_at DESC
  ```
- If both are blank, the query becomes:
  ```sql
  SELECT * FROM users WHERE 1=1 ORDER BY created_at DESC
  ```

### Multiple Variables in a Block

A `[[...]]` block with multiple variables requires **all** of them to have values. If any variable is missing, the entire block is removed:

```sql
SELECT * FROM users
WHERE 1=1
  [[AND age BETWEEN {{min_age}} AND {{max_age}}]]
```

Both `min_age` and `max_age` must be provided for the clause to be included.

### Mixing Required and Optional Variables

Variables outside `[[...]]` blocks are always required. You can mix both in a single query:

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "User Search",
  statement: """
  SELECT * FROM users
  WHERE organization_id = {{org_id}}
    [[AND "name" ILIKE '%' || {{name}} || '%']]
    [[AND "status" = {{status}}]]
  ORDER BY created_at DESC
  LIMIT 100
  """,
  variables: [
    %{name: "org_id", type: :number},
    %{name: "name", type: :text},
    %{name: "status", type: :text}
  ]
})

# org_id is always required; name and status are optional
{:ok, result} = Lotus.run_query(query, vars: %{"org_id" => 1})
```

### Optional Variables with Lists

Optional clauses work with list variables too:

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Filter by Countries",
  statement: """
  SELECT * FROM users
  WHERE 1=1
    [[AND country IN ({{countries}})]]
  """,
  variables: [
    %{name: "countries", type: :text, list: true}
  ]
})

# With values — clause included, list expanded
{:ok, result} = Lotus.run_query(query, vars: %{"countries" => ["US", "UK"]})
# SQL: SELECT * FROM users WHERE 1=1 AND country IN ($1, $2)

# Without values — clause removed
{:ok, result} = Lotus.run_query(query, vars: %{})
# SQL: SELECT * FROM users WHERE 1=1
```

### How It Works

1. Before the adapter transforms the statement, Lotus scans for `[[...]]` blocks
2. For each block, it checks whether all `{{variable}}` references inside have values
3. If all variables have values, the `[[` and `]]` brackets are removed and the content is kept
4. If any variable is missing/nil/empty, the entire block (including brackets) is removed
5. The remainder is then processed normally (variable substitution, type casting, etc.)

`Lotus.Query.OptionalClause` works on text, not on SQL specifically, so the
same syntax applies to any textual query language. An adapter that builds an
AST applies it before serializing.

## Enforcing Limits on Supplied Values

The bound variables reach `:before_query` and `:after_query` middleware under
the `:vars` key — a map keyed by variable name, after defaults and
caller-supplied values are merged. A plug can enforce rules on what the user
picked (a maximum date range, a tenant check) without parsing the statement:

```elixir
%{statement: statement, source: source, context: context, vars: vars} = payload
```

For a raw statement run through `Lotus.run_statement/3`, `:vars` is `%{}`.
See the [middleware guide](middleware.md) for a worked plug.

## Saved Queries Record Their Language

A stored query carries a `:query_language` (for example `"sql:postgres"`),
recorded from the source it was written against. `Lotus.run_query/2`
compares it with the resolved source's language and returns an error rather
than sending the statement to an engine that cannot parse it:

```elixir
{:error, "Query was written for \"sql:postgres\" but data source \"warehouse\" speaks \"sql:clickhouse\""} =
  Lotus.run_query(query, repo: "warehouse")
```

A query with no recorded language runs anywhere, which is how every query
predating the column behaves.

## Automatic Type Casting

Lotus includes an intelligent automatic type casting system that detects column types from your database schema and converts string values (typically from web inputs) to the correct database-native formats.

> **Ecto-backed sources.** The rest of this guide — type casting, the SQL
> transformer, and the interval rewrites — describes the built-in Ecto
> adapter and its Postgres, MySQL and SQLite dialects. A non-SQL adapter
> owns its own substitution and does its own escaping.

### How It Works

When you use a variable in your query, Lotus:

1. **Analyzes the SQL** (`Lotus.Storage.VariableResolver`) to determine which table column the variable is bound to
2. **Queries the schema cache** to get the column's database type
3. **Maps the database type** to a Lotus internal type (`:uuid`, `:integer`, `:date`, etc.)
4. **Casts the value** if needed, or passes it through for text types
5. **Asks the dialect for a placeholder**, with a type annotation where the dialect wants one

This all happens automatically - you don't need to manually specify types in most cases.

Binding resolution is regex-based heuristics, not a full SQL parser: it
handles explicit (`users.id = {{id}}`), implicit (`id = {{id}}`) and aliased
(`u.id = {{id}}`) bindings, and falls back to the variable's declared
`:type` when it cannot resolve one.

### Supported Types

#### UUID Types

Automatically handles UUID columns across different databases:

```elixir
# PostgreSQL uuid column
{:ok, query} = Lotus.create_query(%{
  name: "Find User by UUID",
  statement: "SELECT * FROM users WHERE id = {{user_id}}",
  variables: [%{name: "user_id", default: "550e8400-e29b-41d4-a716-446655440000"}]
})

# Lotus automatically:
# - Detects that 'id' is a uuid column
# - Converts the string to 16-byte binary format
# - Generates: "SELECT * FROM users WHERE id = $1::uuid"
# - Passes the binary value to the database
```

This works with standard UUIDs (v4) and custom UUID formats like UUID v7 (using libraries like Unid).

#### Numeric Types

Automatically casts string numbers to integers, floats, or decimals:

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Products Above Price",
  statement: "SELECT * FROM products WHERE price > {{min_price}}",
  variables: [%{name: "min_price", default: "99.99"}]
})

# If 'price' is a numeric/decimal column:
# - Converts "99.99" string to Decimal value
# - Generates: "SELECT * FROM products WHERE price > $1::numeric"
```

#### Date, Time, and DateTime Types

Parses ISO8601 date and time strings:

```elixir
# Date type
{:ok, query} = Lotus.create_query(%{
  name: "Orders Since Date",
  statement: "SELECT * FROM orders WHERE created_at >= {{since}}",
  variables: [%{name: "since", default: "2024-01-01"}]
})

# If 'created_at' is a date column:
# - Parses "2024-01-01" to a Date struct
# - Generates: "SELECT * FROM orders WHERE created_at >= $1::date"

# Time type
{:ok, query} = Lotus.create_query(%{
  name: "Events After Time",
  statement: "SELECT * FROM events WHERE event_time >= {{start_time}}",
  variables: [%{name: "start_time", default: "10:30:00"}]
})

# If 'event_time' is a time column:
# - Parses "10:30:00" to a Time struct
# - Generates: "SELECT * FROM events WHERE event_time >= $1::time"

# DateTime type
{:ok, query} = Lotus.create_query(%{
  name: "Logs Since Timestamp",
  statement: "SELECT * FROM logs WHERE logged_at >= {{since}}",
  variables: [%{name: "since", default: "2024-01-01T10:30:00"}]
})

# If 'logged_at' is a timestamp column:
# - Parses "2024-01-01T10:30:00" to a NaiveDateTime struct
# - Generates: "SELECT * FROM logs WHERE logged_at >= $1::timestamp"
```

#### Boolean Types

Converts various string formats to native booleans:

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Active Users",
  statement: "SELECT * FROM users WHERE active = {{is_active}}",
  variables: [%{name: "is_active", default: "true"}]
})

# Accepts: "true", "false", "1", "0", "yes", "no", "on", "off"
# Converts to actual boolean: true or false
# SQLite gets integers (1/0), PostgreSQL gets booleans
```

#### Complex PostgreSQL Types

Lotus supports PostgreSQL-specific types:

**Arrays:**
```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Users with Tags",
  statement: "SELECT * FROM users WHERE tags @> {{required_tags}}::text[]",
  variables: [%{name: "required_tags", default: "[\"admin\", \"active\"]"}]
})

# Accepts JSON array format: ["admin", "active"]
# Or PostgreSQL format: {admin,active}
# Casts each element to the array's element type
```

**Enums:**
```elixir
# Enum types (USER-DEFINED) pass through as strings
{:ok, query} = Lotus.create_query(%{
  name: "Orders by Status",
  statement: "SELECT * FROM orders WHERE status = {{order_status}}",
  variables: [%{name: "order_status", default: "pending"}]
})

# If 'status' is an enum type, Lotus passes the string value through
# Database validates it's a valid enum value
```

### Fallback to Manual Types

When automatic type detection fails (e.g., column not found in schema cache), Lotus falls back to manually specified types:

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Manual Type Example",
  statement: "SELECT * FROM computed_view WHERE score > {{min_score}}",
  variables: [
    # Explicitly specify type when automatic detection isn't available
    %{name: "min_score", type: :number, default: "100"}
  ]
})

# Uses the manual :number type annotation
# Generates: "SELECT * FROM computed_view WHERE score > $1::numeric"
```

### Custom Type Handlers

For custom database types (domains, specialized enums, etc.), you can register custom type handlers:

```elixir
# Define a custom type handler
defmodule MyApp.StatusEnumHandler do
  @behaviour Lotus.Storage.TypeHandler

  @impl true
  def cast(value, _opts) do
    if value in ~w(active inactive pending archived) do
      {:ok, value}
    else
      {:error, "Invalid status: must be one of active, inactive, pending, archived"}
    end
  end

  @impl true
  def requires_casting?(_value), do: false
end

# Register in config/config.exs
config :lotus, :type_handlers, %{
  "status_enum" => MyApp.StatusEnumHandler,
  "my_custom_domain" => MyApp.CustomDomainHandler
}
```

Now Lotus will use your custom handler whenever it encounters those database types.

### Error Messages

When type casting fails, Lotus provides clear, user-friendly error messages:

```elixir
# Invalid UUID format
{:error, _} = Lotus.run_query(query, vars: %{"user_id" => "not-a-uuid"})
# Error: Invalid UUID format: 'not-a-uuid' is not a valid UUID (expected format: 8-4-4-4-12 hex digits)

# Invalid date format
{:error, _} = Lotus.run_query(query, vars: %{"since" => "Jan 1st 2024"})
# Error: Invalid date format: 'Jan 1st 2024' is not a valid date (expected ISO8601: YYYY-MM-DD)

# Invalid integer format
{:error, _} = Lotus.run_query(query, vars: %{"age" => "not-a-number"})
# Error: Invalid integer format: 'not-a-number' is not a valid integer

# Invalid boolean format
{:error, _} = Lotus.run_query(query, vars: %{"active" => "maybe"})
# Error: Invalid boolean format: 'maybe' is not a valid boolean (expected: true/false, yes/no, 1/0, on/off)
```

Those messages come from `Lotus.Storage.TypeCaster`, which runs when the
column type was detected. When Lotus falls back to the variable's declared
`:type`, the wording is shorter and carries no format hint — for example
`Invalid number format: 'abc' is not a valid number`.

### Performance Considerations

Type casting adds minimal overhead:

- **Schema cache**: Column types are cached after first lookup (5-minute TTL by default)
- **Smart casting**: Text and enum types skip casting entirely
- **Graceful degradation**: If schema cache fails, falls back to manual types with logging

## SQL Transformer Overview (Ecto Adapters)

The Ecto adapter's dialects rewrite a statement before variables are bound,
through the `transform_statement/1` dialect callback backed by
`Lotus.Source.Adapters.Ecto.SQL.Transformer`. This is what lets one query
text work across Postgres, MySQL and SQLite. It is a dialect concern, not a
core one — an adapter for a non-SQL engine implements whatever
preprocessing its own language needs, or none.

The transformer handles three main areas:
- **Quoted Variable Stripping**: Removes unnecessary quotes around variable placeholders
- **Wildcard Pattern Transformation**: Converts quoted wildcard patterns to database-specific concatenation
- **Interval Query Transformation**: Transforms PostgreSQL interval syntax for compatibility

## Quoted Variable Handling

The transformer automatically handles quoted variables to ensure proper parameter binding across databases.

### Safe Quote Stripping

Variables wrapped in single quotes are automatically stripped when they represent simple scalar values:

```elixir
# Original query
query = %Query{
  statement: "SELECT * FROM users WHERE email = '{{email}}'",
  variables: [%{name: "email", type: :text, default: nil}]
}

# Lotus transforms this to:
# "SELECT * FROM users WHERE email = {{email}}"
# Which becomes: "SELECT * FROM users WHERE email = $1" (PostgreSQL)
```

This works across all supported databases:

**PostgreSQL:**
```sql
-- Original: WHERE name = '{{name}}'
-- Becomes:  WHERE name = $1
```

**MySQL:**
```sql
-- Original: WHERE name = '{{name}}'
-- Becomes:  WHERE name = ?
```

**SQLite:**
```sql
-- Original: WHERE name = '{{name}}'
-- Becomes:  WHERE name = ?
```

### Type Casting Support

Quote stripping works with PostgreSQL type casting:

```elixir
query = %Query{
  statement: "SELECT * FROM users WHERE id = '{{user_id}}'::int",
  variables: [%{name: "user_id", type: :number, default: nil}]
}

# Transforms to: "SELECT * FROM users WHERE id = {{user_id}}::int"
# Final result: "SELECT * FROM users WHERE id = $1::int"
```

### Protected Wildcard Patterns

Wildcard patterns are **NOT** stripped because they need special handling:

```elixir
query = %Query{
  statement: "SELECT * FROM users WHERE name LIKE '%{{search}}%'",
  variables: [%{name: "search", type: :text, default: nil}]
}

# The '%{{search}}%' pattern is preserved and transformed differently
# See Wildcard Pattern Transformation section below
```

## Wildcard Pattern Transformation

One of the most powerful features of the SQL transformer is its ability to handle wildcard search patterns correctly across different database systems.

### The Problem

When you write a query like this:

```sql
SELECT * FROM users WHERE name LIKE '%{{search}}%'
```

The quotes around `%{{search}}%` create a problem: the variable placeholder ends up inside a string literal, which breaks parameter binding and prevents the database from properly executing the query.

### The Solution

Lotus automatically transforms these patterns into database-specific concatenation:

#### PostgreSQL (|| operator)

```elixir
# Original query
statement: "SELECT * FROM users WHERE name LIKE '%{{search}}%'"

# Transforms to:
# "SELECT * FROM users WHERE name LIKE '%' || {{search}} || '%'"

# Final result:
# "SELECT * FROM users WHERE name LIKE '%' || $1 || '%'"
```

#### MySQL (CONCAT function)

```elixir
# Original query
statement: "SELECT * FROM users WHERE name LIKE '%{{search}}%'"

# Transforms to:
# "SELECT * FROM users WHERE name LIKE CONCAT('%', {{search}}, '%')"

# Final result:
# "SELECT * FROM users WHERE name LIKE CONCAT('%', ?, '%')"
```

#### SQLite (|| operator)

```elixir
# Original query
statement: "SELECT * FROM users WHERE name LIKE '%{{search}}%'"

# Transforms to:
# "SELECT * FROM users WHERE name LIKE '%' || {{search}} || '%'"

# Final result:
# "SELECT * FROM users WHERE name LIKE '%' || ? || '%'"
```

### Supported Wildcard Patterns

The transformer recognizes and handles these wildcard patterns:

#### Both-Sided Wildcards: `'%{{var}}%'`
```elixir
# Original
"WHERE title LIKE '%{{search}}%'"

# PostgreSQL/SQLite: "WHERE title LIKE '%' || {{search}} || '%'"
# MySQL: "WHERE title LIKE CONCAT('%', {{search}}, '%')"
```

#### Left Wildcard: `'%{{var}}'`
```elixir
# Original
"WHERE email LIKE '%{{domain}}'"

# PostgreSQL/SQLite: "WHERE email LIKE '%' || {{domain}}"
# MySQL: "WHERE email LIKE CONCAT('%', {{domain}})"
```

#### Right Wildcard: `'{{var}}%'`
```elixir
# Original
"WHERE name LIKE '{{prefix}}%'"

# PostgreSQL/SQLite: "WHERE name LIKE {{prefix}} || '%'"
# MySQL: "WHERE name LIKE CONCAT({{prefix}}, '%')"
```

### Practical Examples

Here are real-world examples of wildcard pattern usage:

#### Flexible Search Query

```elixir
{:ok, search_query} = Lotus.create_query(%{
  name: "User Search",
  statement: """
  SELECT id, name, email
  FROM users
  WHERE
    (name LIKE '%{{search}}%' OR email LIKE '%{{search}}%')
    AND status = {{status}}
  ORDER BY name
  """,
  variables: [
    %{name: "search", type: :text, label: "Search Term", default: ""},
    %{name: "status", type: :text, label: "Status", default: "active"}
  ]
})

# Works identically on PostgreSQL, MySQL, and SQLite
{:ok, result} = Lotus.run_query(search_query, vars: %{
  "search" => "john",
  "status" => "active"
})
```

#### Domain-Based Filtering

```elixir
{:ok, domain_query} = Lotus.create_query(%{
  name: "Users by Email Domain",
  statement: """
  SELECT COUNT(*) as user_count
  FROM users
  WHERE email LIKE '%{{domain}}'
    AND created_at >= {{since}}
  """,
  variables: [
    %{name: "domain", type: :text, label: "Email Domain", default: "@company.com"},
    %{name: "since", type: :date, label: "Since Date", default: "2024-01-01"}
  ]
})

# Execute against different databases
{:ok, pg_result} = Lotus.run_query(domain_query, repo: "postgres")
{:ok, mysql_result} = Lotus.run_query(domain_query, repo: "mysql")
```

## PostgreSQL Interval Query Transformation

For PostgreSQL databases, Lotus provides sophisticated transformation of INTERVAL syntax to make your time-based queries more flexible and variable-friendly.

### Standard PostgreSQL Interval Limitations

PostgreSQL's INTERVAL syntax can be restrictive when you want to use variables:

```sql
-- This works fine
SELECT * FROM posts WHERE created_at > NOW() - INTERVAL '7 days'

-- But this doesn't work with variables in standard SQL
SELECT * FROM posts WHERE created_at > NOW() - INTERVAL '{{days}} days'
```

### Lotus Interval Transformations

Lotus transforms various interval patterns to work seamlessly with variables:

#### Pattern 1: `INTERVAL '{{var}} unit'`

```elixir
# Original query
statement: """
SELECT title FROM posts
WHERE published_at >= NOW() - INTERVAL '{{days}} days'
"""

# Transforms to:
# "SELECT title FROM posts WHERE published_at >= NOW() - make_interval(days => ({{days}})::integer)"
```

#### Pattern 2: `INTERVAL '{{num}} {{unit}}'`

```elixir
# Original query
statement: """
SELECT COUNT(*) FROM events
WHERE created_at >= NOW() - INTERVAL '{{amount}} {{period}}'
"""

# Transforms to:
# "SELECT COUNT(*) FROM events WHERE created_at >= NOW() - ((CAST({{amount}} AS text) || ' ' || {{period}})::interval)"
```

#### Pattern 3: `INTERVAL {{full_interval}}`

```elixir
# Original query
statement: """
SELECT * FROM logs
WHERE timestamp >= NOW() - INTERVAL {{time_range}}
"""

# Transforms to:
# "SELECT * FROM logs WHERE timestamp >= NOW() - ({{time_range}}::text)::interval"
```

#### Pattern 4: `INTERVAL '7 {{unit}}'` (Fixed Number, Variable Unit)

```elixir
# Original query
statement: """
SELECT COUNT(*) FROM sessions
WHERE last_activity >= NOW() - INTERVAL '7 {{unit}}'
"""

# Transforms to:
# "SELECT COUNT(*) FROM sessions WHERE last_activity >= NOW() - (( '7 ' || {{unit}} )::interval)"
```

#### Pattern 5: `INTERVAL '{{var}}'` (Quoted, Whole Interval in the Variable)

```elixir
# Original query
statement: """
SELECT * FROM logs
WHERE logged_at >= NOW() - INTERVAL '{{window}}'
"""

# Transforms to:
# "SELECT * FROM logs WHERE logged_at >= NOW() - CAST({{window}} AS interval)"
```

The variable then holds a complete interval string such as `"3 months"`.

### Practical PostgreSQL Interval Examples

#### Time-Range Analytics Query

```elixir
{:ok, analytics_query} = Lotus.create_query(%{
  name: "Activity Analytics",
  statement: """
  SELECT
    DATE_TRUNC('day', created_at) as day,
    COUNT(*) as events,
    COUNT(DISTINCT user_id) as unique_users
  FROM user_events
  WHERE created_at >= NOW() - INTERVAL '{{days}} days'
  GROUP BY 1
  ORDER BY 1 DESC
  """,
  variables: [
    %{name: "days", type: :number, label: "Days Back", default: "30"}
  ],
  data_source: "postgres"
})

# Execute with different time ranges
{:ok, week_data} = Lotus.run_query(analytics_query, vars: %{"days" => 7})
{:ok, month_data} = Lotus.run_query(analytics_query, vars: %{"days" => 30})
```

#### Flexible Retention Query

```elixir
{:ok, retention_query} = Lotus.create_query(%{
  name: "User Retention Analysis",
  statement: """
  SELECT
    retention_period,
    COUNT(DISTINCT user_id) as active_users,
    ROUND(100.0 * COUNT(DISTINCT user_id) / (
      SELECT COUNT(*) FROM users
      WHERE created_at <= NOW() - INTERVAL '{{period}} {{unit}}'
    ), 2) as retention_rate
  FROM (
    SELECT
      user_id,
      '{{period}} {{unit}}' as retention_period
    FROM user_activity
    WHERE last_seen >= NOW() - INTERVAL '{{period}} {{unit}}'
  ) retention_data
  GROUP BY retention_period
  """,
  variables: [
    %{name: "period", type: :number, label: "Time Period", default: "3"},
    %{name: "unit", type: :text, label: "Time Unit", default: "months",
      widget: :select, static_options: ["days", "weeks", "months", "years"]}
  ],
  data_source: "postgres"
})
```

#### Dynamic Report with Full Interval String

```elixir
{:ok, report_query} = Lotus.create_query(%{
  name: "Flexible Time Report",
  statement: """
  SELECT
    '{{interval}}' as time_range,
    COUNT(*) as total_records,
    AVG(amount) as avg_amount,
    SUM(amount) as total_amount
  FROM transactions
  WHERE created_at >= NOW() - INTERVAL {{interval}}
  """,
  variables: [
    %{name: "interval", type: :text, label: "Time Range", default: "1 month",
      widget: :select, static_options: [
        "1 day", "3 days", "1 week", "2 weeks",
        "1 month", "3 months", "6 months", "1 year"
      ]}
  ],
  data_source: "postgres"
})
```

### Non-PostgreSQL Behavior

For MySQL and SQLite databases, interval transformations are safely ignored since these databases don't support PostgreSQL's INTERVAL syntax:

```elixir
# PostgreSQL query with intervals
{:ok, pg_query} = Lotus.create_query(%{
  name: "PostgreSQL Time Query",
  statement: "SELECT * FROM events WHERE created_at >= NOW() - INTERVAL '{{days}} days'",
  variables: [%{name: "days", type: :number, default: "7"}],
  data_source: "postgres"
})

# MySQL equivalent (no transformation needed)
{:ok, mysql_query} = Lotus.create_query(%{
  name: "MySQL Time Query",
  statement: "SELECT * FROM events WHERE created_at >= NOW() - INTERVAL {{days}} DAY",
  variables: [%{name: "days", type: :number, default: "7"}],
  data_source: "mysql"
})

# SQLite equivalent (no transformation needed)
{:ok, sqlite_query} = Lotus.create_query(%{
  name: "SQLite Time Query",
  statement: "SELECT * FROM events WHERE created_at >= datetime('now', '-' || {{days}} || ' days')",
  variables: [%{name: "days", type: :number, default: "7"}],
  data_source: "sqlite"
})
```
