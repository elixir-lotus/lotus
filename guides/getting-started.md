# Getting Started

This guide will walk you through your first steps with Lotus, from creating your first query to understanding the results.

## Prerequisites

Before starting, make sure you have:

- Completed the [Installation](installation.md) guide
- A running Elixir application with Ecto and Lotus configured
- Some data in your database to query

> **Coming from Lotus 0.x?** The API in this guide is v1.0 only. Config keys and
> several function names changed, and there is no compatibility shim — read
> [Upgrading to v1.0](upgrading-to-v1.md) first. In particular `Lotus.run_sql`
> is now `Lotus.run_statement/3` and `Lotus.get_table_schema` is now
> `Lotus.describe_table/3`.

## Your First Query

### Creating a Saved Query

Let's create and save a simple query:

```elixir
# Create a new query
{:ok, query} = Lotus.create_query(%{
  name: "Count Users",
  statement: "SELECT COUNT(*) AS user_count FROM users"
})

IO.inspect(query)
# %Lotus.Storage.Query{
#   id: 1,
#   name: "Count Users",
#   description: nil,
#   statement: "SELECT COUNT(*) AS user_count FROM users",
#   variables: [],
#   data_source: nil,
#   search_path: nil,
#   query_language: nil,
#   inserted_at: ~U[2024-01-15 10:30:00.000000Z],
#   updated_at: ~U[2024-01-15 10:30:00.000000Z]
# }
```

A query needs a `name` and a `statement`. Everything else is optional:
`description`, `variables`, `data_source`, `search_path` and `query_language`.
For Ecto-backed sources the statement is SQL text; for a non-Ecto adapter it is
whatever that adapter accepts.

### Running the Query

Now let's execute our saved query:

```elixir
# Execute the saved query
{:ok, result} = Lotus.run_query(query)

IO.inspect(result)
# %Lotus.Result{
#   columns: ["user_count"],
#   rows: [[42]],
#   num_rows: 1
# }
```

### Accessing Results

The `Result` struct contains all the information about your query execution:

```elixir
# Get the column names
result.columns
# ["user_count"]

# Get the data rows
result.rows
# [[42]]

# Get the number of rows returned
result.num_rows
# 1

# The %Lotus.Result{} struct contains:
# - columns:     list of column names
# - rows:        list of result rows
# - num_rows:    number of rows in the returned page
# - duration_ms: execution time in milliseconds (nil if not measured)
# - command:     the command the adapter reported (e.g. "select"), or nil
# - meta:        adapter and pagination metadata (see Paging Through Results)
```

`Lotus.Result.to_encodable/1` returns a JSON-safe map of the same fields, with
row values normalized (UUIDs, dates, decimals and so on).

## Ad-hoc Queries

Sometimes you want to run a query without saving it first:

```elixir
# Run SQL directly
{:ok, result} = Lotus.run_statement(
  "SELECT name, email FROM users WHERE active = $1 LIMIT $2",
  [true, 10]
)

IO.inspect(result.columns)
# ["name", "email"]

IO.inspect(result.rows)
# [
#   ["Alice Johnson", "alice@example.com"],
#   ["Bob Smith", "bob@example.com"],
#   ...
# ]
```

## Working with Multiple Data Sources

Lotus supports PostgreSQL, MySQL, and SQLite databases. If you have configured multiple data sources, you can execute queries against specific databases:

```elixir
# Execute against a specific repository by name
{:ok, result} = Lotus.run_statement(
  "SELECT COUNT(*) FROM page_views WHERE date = $1",
  [Date.utc_today()],
  repo: "analytics"
)

# Execute against a repository module directly
{:ok, result} = Lotus.run_statement(
  "SELECT SUM(amount) FROM transactions",
  [],
  repo: MyApp.MySQLRepo
)

# List all available data sources
source_names = Lotus.list_data_source_names()
IO.inspect(source_names)
# ["postgres", "mysql", "sqlite", "analytics"]
```

### Storing Queries with Specific Data Sources

You can store queries with a specific data source, so they automatically execute against the correct database:

```elixir
# Create a query that will run against the analytics database.
# Stored queries take no positional params — use {{variables}} instead.
{:ok, analytics_query} = Lotus.create_query(%{
  name: "Daily Page Views",
  statement: "SELECT COUNT(*) FROM page_views WHERE date = {{on_date}}",
  variables: [
    %{name: "on_date", type: :date, label: "Date", default: Date.to_iso8601(Date.utc_today())}
  ],
  data_source: "analytics"
})

# Create a query for the main database
{:ok, user_query} = Lotus.create_query(%{
  name: "Active Users",
  statement: "SELECT COUNT(*) FROM users WHERE active = true",
  data_source: "main"
})

# Execute queries - they automatically use their stored data_source
{:ok, analytics_result} = Lotus.run_query(analytics_query)
{:ok, user_result} = Lotus.run_query(user_query)
```

### Runtime Repository Override

You can override the stored data source at execution time:

```elixir
# Query was saved with data_source: "analytics"
{:ok, query} = Lotus.create_query(%{
  name: "User Count",
  statement: "SELECT COUNT(*) FROM users",
  data_source: "analytics"
})

# Execute against the stored repository
{:ok, result} = Lotus.run_query(query)

# Override at runtime to use a different repository
{:ok, result} = Lotus.run_query(query, repo: "main")
```

### Default Data Source Behavior

If you don't specify a `data_source` when creating a query, it will use the configured `default_source` when executed:

```elixir
# Configuration with default_source
config :lotus,
  default_source: "main",
  data_sources: %{
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  }

# Query without specific data_source
{:ok, query} = Lotus.create_query(%{
  name: "Generic Query",
  statement: "SELECT 1"
  # No data_source specified
})

# Will use the "main" data source (from default_source config)
{:ok, result} = Lotus.run_query(query)
```

### Recording the Query Language

A saved query can record the language it was written for in `query_language`,
as a `family:dialect` identifier — `"sql:postgres"`, `"json:elasticsearch"`.
A bare family (`"sql"`) is also accepted.

```elixir
{:ok, query} = Lotus.create_query(%{
  name: "Recent Signups",
  statement: "SELECT id, email FROM users WHERE created_at > NOW() - INTERVAL '7 days'",
  data_source: "postgres",
  query_language: "sql:postgres"
})
```

When the query runs, Lotus compares the recorded language with the language of
the resolved data source. A mismatch stops execution instead of handing the
statement to an engine that cannot parse it:

```elixir
{:error, reason} = Lotus.run_query(query, repo: "sqlite")
IO.puts(reason)
# Query was written for "sql:postgres" but data source "sqlite" speaks "sql:sqlite"
```

The comparison is exact, not family-level: `sql:postgres` and `sql:sqlite` share
a family but are not interchangeable. `query_language` is optional — leave it
`nil` and the query runs against whatever source it resolves to, with the
language derived from that source's adapter.

## Managing Saved Queries

### Listing All Queries

```elixir
# Get all saved queries
queries = Lotus.list_queries()

Enum.each(queries, fn query ->
  IO.puts("#{query.id}: #{query.name}")
end)
# 1: Count Users
# 2: Active Users Report
# 3: Monthly Sales Summary
```

### Finding a Specific Query

```elixir
# Get a query by ID
query = Lotus.get_query!(1)
IO.puts(query.name)
# "Count Users"
```

### Updating a Query

```elixir
# Update an existing query
{:ok, updated_query} = Lotus.update_query(query, %{
  name: "Total User Count",
  statement: "SELECT COUNT(*) AS total_users FROM users WHERE deleted_at IS NULL"
})

IO.puts(updated_query.name)
# "Total User Count"
```

### Deleting a Query

```elixir
# Delete a query
{:ok, _deleted_query} = Lotus.delete_query(query)

# Verify it's gone
try do
  Lotus.get_query!(query.id)
rescue
  Ecto.NoResultsError -> IO.puts("Query deleted successfully")
end
```

## Working with Visualizations

Lotus supports saving chart configurations (visualizations) alongside your queries. Visualizations use a renderer-agnostic DSL that can be transformed by frontend applications like Lotus Web into concrete chart specs (Vega-Lite, Recharts, etc.).

### Creating a Visualization

```elixir
# First, create or get a query
{:ok, query} = Lotus.create_query(%{
  name: "Monthly Revenue",
  statement: "SELECT date_trunc('month', created_at) as month, SUM(amount) as revenue, region FROM orders GROUP BY 1, 2"
})

# Create a visualization for the query
{:ok, viz} = Lotus.create_visualization(query, %{
  name: "Revenue by Region",
  position: 0,
  config: %{
    "chart" => "line",
    "x" => %{"field" => "month", "kind" => "temporal", "timeUnit" => "month"},
    "y" => [%{"field" => "revenue", "agg" => "sum"}],
    "series" => %{"field" => "region"},
    "options" => %{"legend" => true}
  }
})

IO.inspect(viz)
# %Lotus.Storage.QueryVisualization{
#   id: 1,
#   query_id: 1,
#   name: "Revenue by Region",
#   position: 0,
#   config: %{...},
#   version: 1
# }
```

### Visualization Config DSL

Lotus stores visualization configs as opaque maps, giving you full flexibility. The structure below is the recommended format used by Lotus Web, but you can store any valid map that suits your charting library.

The config uses a neutral format that maps to common charting concepts:

```elixir
%{
  # Chart type (required)
  "chart" => "line",  # line | bar | area | scatter | table | number | heatmap

  # X-axis configuration (optional)
  "x" => %{
    "field" => "month",           # Column name from query results
    "kind" => "temporal",         # temporal | quantitative | nominal
    "timeUnit" => "month"         # Optional: year | quarter | month | week | day
  },

  # Y-axis configuration (optional, list of fields)
  "y" => [
    %{"field" => "revenue", "agg" => "sum"},   # agg: sum | avg | count
    %{"field" => "cost", "agg" => "sum"}
  ],

  # Series/color grouping (optional)
  "series" => %{"field" => "region"},

  # Client-side filters (optional)
  "filters" => [
    %{"field" => "region", "op" => "=", "value" => "EMEA"}  # op: = | != | < | <= | > | >= | in | not in
  ],

  # Display options (optional)
  "options" => %{
    "legend" => true,
    "stack" => "none"  # none | stack | normalize
  }
}
```

### Listing Visualizations

```elixir
# Get all visualizations for a query (ordered by position)
visualizations = Lotus.list_visualizations(query.id)

Enum.each(visualizations, fn viz ->
  IO.puts("#{viz.position}: #{viz.name} (#{viz.config["chart"]})")
end)
# 0: Revenue by Region (line)
# 1: Revenue Table (table)
```

### Validating Against Query Results

Lotus provides optional validation to check that your config references valid columns from the query results. This validation does **not** enforce any particular config structure—it only checks field references.

```elixir
# Run the query to get results
{:ok, result} = Lotus.run_query(query)

# Validate the visualization config
config = %{
  "chart" => "bar",
  "y" => [%{"field" => "nonexistent_column", "agg" => "sum"}]
}

case Lotus.validate_visualization_config(config, result) do
  :ok ->
    IO.puts("Config is valid")
  {:error, msg} ->
    IO.puts("Invalid config: #{msg}")
    # "y[0].field references unknown column 'nonexistent_column'"
end
```

The validation checks:
- Fields referenced in `x`, `y`, `series`, and `filters` exist in the result columns
- Numeric aggregations (`sum`, `avg`) are only applied to numeric columns

Note: This validation is optional. You can save any valid map as a visualization config.

### Updating and Deleting Visualizations

```elixir
# Update a visualization
{:ok, updated_viz} = Lotus.update_visualization(viz, %{
  name: "Updated Chart Name",
  position: 1
})

# Delete a visualization
{:ok, _} = Lotus.delete_visualization(viz)

# Visualizations are also cascade-deleted when their parent query is deleted
```

## PostgreSQL Schema Resolution with search_path

When working with PostgreSQL databases that use multiple schemas, you can use `search_path` to resolve unqualified table names. This is especially useful for multi-tenant applications or when you have separate schemas for reporting, analytics, or different environments.

### Understanding search_path

PostgreSQL's `search_path` determines which schemas are searched when you reference an unqualified table name like `users` instead of `reporting.users`. For example:

```elixir
# Without search_path - must fully qualify table names
{:error, reason} = Lotus.run_statement("SELECT * FROM customers")
# "SQL error: relation \"customers\" does not exist"

# With search_path - finds reporting.customers automatically
{:ok, result} = Lotus.run_statement(
  "SELECT * FROM customers", 
  [], 
  search_path: "reporting, public"
)
```

### Stored Queries with search_path

You can save a `search_path` with your queries to make them automatically resolve against the correct schemas:

```elixir
# Create a query that looks in reporting schema first, then public
{:ok, query} = Lotus.create_query(%{
  name: "Customer Report",
  statement: "SELECT COUNT(*) FROM customers WHERE active = true",
  search_path: "reporting, public",
  data_source: "postgres"
})

# Execute - automatically uses the stored search_path
{:ok, result} = Lotus.run_query(query)
# Finds reporting.customers without needing to qualify the table name
```

### Runtime search_path Override

You can override or provide a `search_path` at runtime:

```elixir
# Override stored search_path
{:ok, result} = Lotus.run_query(query, search_path: "analytics, public")

# Provide search_path for ad-hoc queries
{:ok, result} = Lotus.run_statement(
  "SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id",
  [],
  repo: "postgres",
  search_path: "reporting, public"
)
```

### Multi-Schema Scenarios

Here are common patterns for using `search_path`:

#### Multi-Tenant with Schema-per-Tenant

```elixir
# Query template that works across tenant schemas
{:ok, tenant_query} = Lotus.create_query(%{
  name: "Tenant User Count",
  statement: "SELECT COUNT(*) FROM users WHERE active = {{is_active}}",
  variables: [
    %{name: "is_active", type: :text, label: "Is Active", default: "true"}
  ],
  data_source: "postgres"
})

# Execute for different tenants by overriding search_path
{:ok, tenant_a_result} = Lotus.run_query(tenant_query, search_path: "tenant_123, public")
{:ok, tenant_b_result} = Lotus.run_query(tenant_query, search_path: "tenant_456, public") 
```

#### Reporting and Analytics Schemas

```elixir
# Create queries that work across different schema contexts
{:ok, report_query} = Lotus.create_query(%{
  name: "Monthly Revenue",
  statement: """
  SELECT
    DATE_TRUNC('month', created_at) AS month,
    SUM(amount) AS revenue
  FROM orders
  WHERE created_at >= {{since}}
  GROUP BY 1
  ORDER BY 1
  """,
  variables: [
    %{name: "since", type: :date, label: "Since", default: "2024-01-01"}
  ],
  search_path: "reporting, public",
  data_source: "postgres"
})

# Use the same query structure for different contexts.
# run_query/2 takes options only — values go through `vars:`.
{:ok, prod_data} = Lotus.run_query(report_query, vars: %{"since" => "2024-01-01"})

{:ok, staging_data} =
  Lotus.run_query(report_query,
    vars: %{"since" => "2024-01-01"},
    search_path: "staging, public"
  )
```

#### Mixed Schema Access

```elixir
# Query that needs tables from multiple schemas in search order
{:ok, complex_query} = Lotus.create_query(%{
  name: "User Activity Summary",
  statement: """
  SELECT
    u.name,
    COUNT(e.id) AS event_count,
    MAX(s.last_login) AS last_seen
  FROM users u
  LEFT JOIN events e ON u.id = e.user_id  -- from analytics schema
  LEFT JOIN sessions s ON u.id = s.user_id  -- from public schema
  GROUP BY u.id, u.name
  """,
  search_path: "public, analytics",  # users in public, events in analytics
  data_source: "postgres"
})
```

### search_path Validation

Lotus validates `search_path` values to prevent injection attacks:

```elixir
# Valid search_path values
{:ok, query} = Lotus.create_query(%{
  name: "Valid Query",
  statement: "SELECT 1",
  search_path: "reporting"  # single schema
})

{:ok, query} = Lotus.create_query(%{
  name: "Valid Query",  
  statement: "SELECT 1",
  search_path: "schema1, schema_2, public"  # multiple schemas
})

# Invalid search_path - validation error
{:error, changeset} = Lotus.create_query(%{
  name: "Invalid Query",
  statement: "SELECT 1", 
  search_path: "invalid-name, 123schema"  # hyphens and leading numbers not allowed
})

changeset.errors
# [search_path: {"must be a comma-separated list of identifiers", []}]
```

### search_path with Other Databases

For non-PostgreSQL databases, `search_path` is safely ignored:

```elixir
# SQLite ignores search_path without error
{:ok, result} = Lotus.run_statement(
  "SELECT COUNT(*) FROM products",
  [],
  repo: "sqlite",
  search_path: "ignored_value"  # Has no effect but doesn't cause errors
)
```

### Safety and Scoping

Lotus implements `search_path` safely:

- Uses `SET LOCAL search_path` to scope changes to the current transaction only
- Changes don't leak to other queries or database sessions  
- The same `search_path` is used for both preflight authorization and query execution
- Schema identifiers are validated to prevent injection attacks

## Working with Smart Variables

Lotus supports smart variable substitution using `{{var}}` placeholders for safety and reusability:

```elixir
# Create a query with smart variables
{:ok, query} = Lotus.create_query(%{
  name: "Users by Status",
  statement: "SELECT id, name, email FROM users WHERE status = {{status}} AND created_at > {{created_date}}",
  variables: [
    %{name: "status", type: :text, label: "User Status", default: "active"},
    %{name: "created_date", type: :date, label: "Created After", default: "2024-01-01"}
  ]
})

# Run with the default variables
{:ok, result} = Lotus.run_query(query)

# Override variables at runtime
{:ok, result} = Lotus.run_query(query, vars: %{
  "status" => "pending",
  "created_date" => "2024-06-01"
})
```

### Variable Types and Widgets

Variables can be configured with different types and UI widgets to create better user interfaces:

```elixir
# Example with different variable types and widgets
attrs = %{
  name: "Active Users",
  statement: "SELECT * FROM users WHERE org_id = {{org_id}} AND created_at >= {{since}} AND status = {{status}}",
  variables: [
    # Number input with default
    %{name: "org_id", type: :number, label: "Organization ID", default: "1"},
    
    # Date input
    %{name: "since", type: :date, label: "Created Since"},
    
    # Static dropdown with predefined options
    %{
      name: "status", 
      type: :text, 
      widget: :select, 
      label: "Status",
      static_options: ["active", "inactive", "pending"]
    }
  ]
}

{:ok, q} = Lotus.create_query(attrs)

# compile/2 turns a stored query plus its variable values into an
# executable %Lotus.Query.Statement{}. run_query/2 does this for you;
# call it directly when you want to inspect what will be sent.
Lotus.Storage.Query.compile(q, %{"since" => "2024-01-01"})
# On PostgreSQL, against a table whose org_id is an integer column and
# whose created_at is a date column:
# => {:ok,
#     %Lotus.Query.Statement{
#       adapter: Lotus.Source.Adapters.Postgres,
#       body: "SELECT * FROM users WHERE org_id = $1::integer AND created_at >= $2::date AND status = $3",
#       params: [1, ~D[2024-01-01], "active"],
#       meta: %{}
#     }}
```

The `::integer` / `::date` suffixes are not fixed per variable type, so the same
query compiles differently against a different table. Lotus looks up the type of
the column each variable is compared against and uses that; the declared
variable type is only the fallback, used when the column type is unknown or
plain text. See [Variable Type Casting](#variable-type-casting) below.

`compile/2` returns `{:error, reason}` when a required variable has no value, a
list variable is empty, or a supplied value fails type casting. `compile!/2` is
the raising variant and returns the `%Statement{}` directly.

> **Renamed in v1.0.** `compile/2` was `to_sql_params/2` in 0.x, and it returned
> a bare `{sql, params}` tuple. The `body` field is adapter-native — SQL text for
> Ecto sources, a JSON payload or AST for others — so it is no longer always a
> string.

### Dynamic Dropdown Options

For select widgets, you can populate options dynamically using `options_query`:

```elixir
# Dynamic dropdown populated from database
%{
  name: "org_id",
  type: :number,
  widget: :select,
  label: "Organization",
  options_query: "SELECT id, name FROM orgs ORDER BY name"
}
```

The `options_query` should return two columns:
- First column: the value to be used in the query
- Second column: the label to display to users

### Variable Features

- **Safe substitution**: Variables are converted to database-specific placeholders with automatic type casting (`$1::integer` for PostgreSQL, `CAST(? AS SIGNED)` for MySQL, `?` for SQLite)
- **Structured variables**: Define variables with type, label, and default values for better UI integration
- **Declared types**: A variable declares one of `:text`, `:number` or `:date`. Richer types (integer, boolean, datetime, uuid, json, arrays and more) are inferred from the column the variable is compared against
- **Widget controls**: Specify input or select widgets for UI rendering
- **Static options**: Use `static_options` for predefined dropdown choices
- **Dynamic options**: Use `options_query` to populate dropdowns from database queries
- **Default values**: Provide fallback values in variable definitions
- **Runtime override**: Pass `vars:` option to override defaults
- **Multiple occurrences**: The same variable can appear multiple times and will be bound correctly
- **Type safety**: Variables are passed as parameters, preventing SQL injection

## Variable Type Casting

For SQL sources, Lotus generates a type-specific placeholder for every
substituted variable, so the database engine receives the value in the right
type.

**How the type is chosen**, in order:

1. The type of the column the variable is compared against, when Lotus can
   introspect it and it is not plain text. This wins, because the column knows
   better than the declaration.
2. The variable's declared `:type` (`:text`, `:number` or `:date`).
3. No type — the value is passed through untouched.

### PostgreSQL Type Casting
- `:integer` → `$1::integer`
- `:number` / `:decimal` → `$1::numeric`
- `:float` → `$1::real`
- `:uuid` → `$1::uuid`
- `:date` → `$1::date`
- `:datetime` → `$1::timestamp`
- `:time` → `$1::time`
- `:boolean` → `$1::boolean`
- `:json` → `$1::jsonb`
- `:binary` → `$1::bytea`
- `:text` (default) → `$1`

### MySQL Type Casting
- `:integer` → `CAST(? AS SIGNED)`
- `:number` → `CAST(? AS DECIMAL)`
- `:date` → `CAST(? AS DATE)`
- `:datetime` → `CAST(? AS DATETIME)`
- `:time` → `CAST(? AS TIME)`
- `:boolean` → `CAST(? AS UNSIGNED)`
- `:json` → `CAST(? AS JSON)`
- `:text` (default) → `?`

### SQLite
SQLite uses untyped `?` placeholders for all variable types, as it handles type conversion automatically.

### Non-SQL sources
Placeholders are an adapter decision, not a Lotus one. An adapter for a JSON or
DSL engine inlines the value as a properly escaped literal in its own payload
instead of adding a bind placeholder. See the
[Source Adapters guide](source-adapters.md).

## Error Handling

Lotus provides clear error messages for common issues:

```elixir
# Invalid SQL
{:error, reason} = Lotus.run_statement("SELCT * FROM users")  # typo in SELECT
IO.inspect(reason)
# "SQL syntax error: syntax error at or near \"SELCT\""

# Attempting destructive operation
{:error, reason} = Lotus.run_statement("DROP TABLE users")
IO.inspect(reason)
# "Only read-only queries are allowed"

# Query timeout
{:error, reason} = Lotus.run_statement(
  "SELECT pg_sleep(10)",
  [],
  timeout: 1000  # 1 second timeout
)
IO.inspect(reason)
# "SQL error: canceling statement due to user request"

# Table visibility restriction
{:error, reason} = Lotus.run_statement("SELECT * FROM schema_migrations")
IO.inspect(reason)
# "Query touches blocked table(s): schema_migrations"
```

## Configuration Options

You can customize query execution with options:

```elixir
# Set a custom timeout
{:ok, result} = Lotus.run_query(query, timeout: 30_000)

# Use a search_path for schema resolution
{:ok, result} = Lotus.run_query(query, search_path: "reporting, public")

# Combine multiple options
{:ok, result} = Lotus.run_query(query, [
  timeout: 30_000,
  search_path: "reporting, public",
  statement_timeout_ms: 25_000
])
```

Both `run_query/2` and `run_statement/3` accept the same option list:
`:timeout`, `:statement_timeout_ms`, `:read_only`, `:search_path`, `:repo`,
`:vars`, `:cache`, `:window`, `:filters`, `:sorts`, `:context` and `:scope`.

## Paging Through Results

Pass `:window` to return one page of rows instead of the whole result set:

```elixir
{:ok, page} = Lotus.run_query(query, window: [limit: 50, offset: 100])

page.num_rows
# 50 — always the number of rows in the returned page

page.meta.window
# %{limit: 50, offset: 100}
```

Ask for a total with `count: :exact`:

```elixir
{:ok, page} = Lotus.run_query(query, window: [limit: 50, offset: 0, count: :exact])

page.meta.total_count
# 1842 — rows before the window was applied
page.meta.total_mode
# :exact
```

`meta.total_mode` reports what you asked for, not how the source produced it. A
source that cannot produce a total still reports `:exact` with
`total_count: nil`, so an honest "unknown" is never confused with zero. With
`count: :none` (the default) `meta` carries only `:window`.

Windows also work on ad-hoc statements, and each page is cached separately:

```elixir
{:ok, page} = Lotus.run_statement("SELECT * FROM orders ORDER BY id", [],
  window: [limit: 25, offset: 0, count: :exact]
)
```

Set `config :lotus, default_page_size: 100` to change the limit used when a
window names no `:limit`.

## Best Practices

### 1. Use Descriptive Names

```elixir
# Good
Lotus.create_query(%{
  name: "Monthly Active Users Report",
  statement: "..."
})

# Avoid
Lotus.create_query(%{
  name: "Query 1",
  statement: "..."
})
```

### 2. Always Use Parameters for Dynamic Values

```elixir
# Good - safe from SQL injection
Lotus.run_statement(
  "SELECT * FROM users WHERE status = $1",
  [user_status]
)

# Avoid - vulnerable to SQL injection
Lotus.run_statement("SELECT * FROM users WHERE status = '#{user_status}'")
```

### 3. Handle Errors Gracefully

```elixir
case Lotus.run_query(query) do
  {:ok, result} ->
    process_results(result)

  {:error, reason} ->
    Logger.error("Query failed: #{inspect(reason)}")
    {:error, "Unable to generate report"}
end
```

## Using Lotus Web

If you prefer a visual interface or need to provide query access to non-technical users, consider setting up [Lotus Web](https://github.com/elixir-lotus/lotus_web). It provides a beautiful web interface that mounts directly in your Phoenix application:

```elixir
# In your router
import Lotus.Web.Router

scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]
  
  lotus_dashboard "/lotus"
end
```

With Lotus Web, you get:
- A SQL editor with syntax highlighting
- Visual query management and organization
- Interactive schema exploration
- Real-time result visualization
- All without leaving your application

See the [installation guide](installation.md#lotus-web-setup) for detailed setup instructions.

## Building Dashboards

Once you have queries and visualizations, you can combine them into dashboards for interactive reporting:

```elixir
# Create a dashboard
{:ok, dashboard} = Lotus.create_dashboard(%{
  name: "Sales Overview",
  description: "Key sales metrics"
})

# Add query cards
{:ok, card} = Lotus.create_dashboard_card(dashboard, %{
  card_type: :query,
  query_id: query.id,
  title: "Monthly Revenue",
  position: 0,
  layout: %{x: 0, y: 0, w: 6, h: 4}
})

# Add a filter that applies to multiple cards
{:ok, filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "date_range",
  label: "Date Range",
  filter_type: :date_range,
  widget: :date_range_picker,
  position: 0
})

# Map the filter to a query variable
Lotus.create_filter_mapping(card, filter, "start_date")

# Run the dashboard
{:ok, results} = Lotus.run_dashboard(dashboard,
  filter_values: %{"date_range" => "2024-01-01/2024-03-31"}
)
```

See the [Dashboards guide](dashboards.md) for complete documentation.

## Next Steps

Now that you understand the basics, explore:

- [Dashboards](dashboards.md) - Combine queries into interactive views
- [Configuration](configuration.md) - Learn about all available configuration options
- [Advanced Variables](advanced-variables.md) - Optional clauses, list variables and dynamic options
- [Visibility](visibility.md) - Control which schemas, tables and columns queries can reach
- [Source Adapters](source-adapters.md) - Add a SQL dialect or a non-SQL data source
- [Upgrading to v1.0](upgrading-to-v1.md) - Porting an app from the 0.x API
