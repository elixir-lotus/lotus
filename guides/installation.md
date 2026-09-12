# Installation

This guide walks you through setting up Lotus in your Elixir application.

## Requirements

- Elixir 1.18 or later
- OTP 27 or later
- An Ecto repository on PostgreSQL, MySQL, or SQLite for Lotus storage
  - **SQLite**: Version 3.8.0+ recommended for database-level read-only protection

Lotus keeps its saved queries, visualizations and dashboards in one Ecto
repository — the *storage repo*. The databases that queries actually run
against — the *data sources* — do not have to be Ecto repos in v1.0. Any module
that implements the `Lotus.Source.Adapter` behaviour can be registered as a
source. See the [Source Adapters guide](source-adapters.md).

> **Upgrading from 0.x?** v1.0 renames configuration keys, public functions and
> a database column, and there is no compatibility shim. Read
> [Upgrading to v1.0](upgrading-to-v1.md) before you change anything.

## Step 1: Add Dependency

Add `lotus` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lotus, "~> 1.0"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

## Step 2: Configuration

Add Lotus configuration to your `config/config.exs`:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,     # Where Lotus stores saved queries
  default_source: "main",       # Default data source for queries (required with multiple sources)
  data_sources: %{              # Where queries execute
    "main" => MyApp.Repo,
    "analytics" => MyApp.AnalyticsRepo
  }
```

### Configuration Options

Only `:storage_repo` is required. Everything else has a default.

- `storage_repo` (required): Ecto repository where Lotus stores its query definitions
- `data_sources`: Map of named data sources where queries can be executed (default: `%{}`). Values are Ecto repo modules, or config maps for non-Ecto adapters
- `default_source`: Data source name to use when a query names none. Must be a key in `data_sources`; Lotus raises at boot if it is not
- `read_only`: Blocks writes (INSERT, UPDATE, DELETE, DDL) at the application and database level (default: `true`)
- `unique_names`: Whether to enforce unique query names (default: `true`)
- `default_page_size`: Global default page size for windowed pagination (default: `nil`, which uses the built-in default)
- `table_visibility` / `schema_visibility` / `column_visibility`: Rules controlling which schemas, tables and columns Lotus can reach — see the [Visibility Guide](visibility.md)
- `allow_unrestricted_resources`: Opt-in for sources whose adapter cannot report the resources a statement touches (default: `false`) — see below
- `cache`: Cache adapter, namespace and profiles — see the [Caching Guide](caching.md)
- `middleware`: Hooks around query execution and schema discovery — see the [Middleware Guide](middleware.md)
- `source_adapters` / `trusted_source_adapters` / `source_resolver` / `visibility_resolver`: Extension points for custom adapters and resolvers — see the [Source Adapters guide](source-adapters.md) and [Custom Resolvers](custom-resolvers.md)

> **Renamed in v1.0.** `:ecto_repo` is now `:storage_repo`, `:data_repos` is now
> `:data_sources`, and `:default_repo` is now `:default_source`. There is no
> compatibility shim: Lotus reads only the new names, so a leftover 0.x key has
> no effect and the app fails as though the setting were missing. See
> Troubleshooting below.

### Non-SQL Data Sources

A data source entry may be a config map instead of a repo module, which is how
non-Ecto adapters are configured:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,
  data_sources: %{
    "main" => MyApp.Repo,
    "events" => %{adapter: MyApp.ElasticsearchAdapter, url: "http://localhost:9200"}
  }
```

`%{adapter: MyAdapter, ...}` is the canonical form: the named module is used
directly and the whole map is handed to it as state. Use `:source_adapters` only
when an entry does not name its adapter and you want Lotus to find the owner by
asking each registered module — exactly one must claim it, or resolution raises.

Before it runs a statement, Lotus asks the adapter which resources the
statement touches, so it can apply visibility rules. Some engines cannot answer
that — they control access at their own layer (an Elasticsearch index, for
example). Lotus blocks those statements unless you opt in:

```elixir
config :lotus,
  # Opt in for one source only (recommended)
  data_sources: %{
    "events" => %{
      adapter: MyApp.ElasticsearchAdapter,
      url: "http://localhost:9200",
      allow_unrestricted_resources: true
    }
  }

# Or globally, for every such source
config :lotus, allow_unrestricted_resources: true
```

The per-source setting always wins over the global flag, in both directions.
See the [Visibility Guide](visibility.md) for the full rule model.

## Step 3: Run Migrations

Lotus needs to create tables in your database to store queries. Generate and run the migration:

```bash
mix ecto.gen.migration create_lotus_tables
```

Add the Lotus migration to your generated migration file:

```elixir
defmodule MyApp.Repo.Migrations.CreateLotusTables do
  use Ecto.Migration

  def up do
    Lotus.Migrations.up()
  end

  def down do
    Lotus.Migrations.down()
  end
end
```

Run the migration:

```bash
mix ecto.migrate
```

This creates the `lotus_queries`, `lotus_query_visualizations`,
`lotus_dashboards`, `lotus_dashboard_cards`, `lotus_dashboard_filters` and
`lotus_dashboard_card_filter_mappings` tables in your storage repo.

`Lotus.Migrations.up/1` and `down/1` dispatch on the storage repo's adapter and
accept a `:prefix` option if you keep Lotus tables in another schema:

```elixir
def up, do: Lotus.Migrations.up(prefix: "analytics")
def down, do: Lotus.Migrations.down(prefix: "analytics")
```

`Lotus.Migrations.migrated_version/1` reports the version the database is on.

> **Postgres is versioned; MySQL and SQLite are not.** The Postgres migration
> runs a numbered chain (V1..V5), so `mix ecto.migrate` applies later changes —
> including the v1.0 `data_repo` → `data_source` rename and the new
> `query_language` column — on its own. The MySQL and SQLite migrations are
> single-file and unversioned, so a host upgrading an existing 0.x install must
> run those two statements by hand before starting v1.0 app code. Lotus raises a
> migration error naming the rename statement if it finds the old `data_repo`
> column; the `query_language` column is not checked, so add it at the same
> time. Fresh installs are unaffected on every database. The exact SQL is in
> [Upgrading to v1.0](upgrading-to-v1.md).

## Step 4: Configure Caching (Optional)

Lotus is an OTP application — its supervisor starts automatically with your app, so you do not need to add `Lotus` to your application's supervision tree.

To enable caching, just add a `:cache` entry to your Lotus configuration:

```elixir
# config/config.exs
config :lotus,
  storage_repo: MyApp.Repo,
  data_sources: %{"main" => MyApp.Repo},
  cache: %{
    adapter: Lotus.Cache.ETS,
    namespace: "myapp_lotus"
  }
```

See the [Caching Guide](caching.md) for full details.

## Step 5: Verify Installation

Test that Lotus is working correctly:

```elixir
# In iex -S mix
iex> Lotus.run_statement("SELECT 1 as test")
{:ok, %Lotus.Result{rows: [[1]], columns: ["test"], num_rows: 1}}
```

## Database-Specific Setup

### PostgreSQL

Lotus works out of the box with PostgreSQL. Ensure your repository is configured with the `:postgrex` adapter:

```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "my_app_dev"
```

### SQLite

Lotus supports SQLite through the `ecto_sqlite3` adapter. Add the dependency to your `mix.exs`:

```elixir
{:ecto_sqlite3, "~> 0.11"}
```

Configure your SQLite repository:

```elixir
config :my_app, MyApp.SqliteRepo,
  adapter: Ecto.Adapters.SQLite3,
  database: Path.expand("../my_app.db", Path.dirname(__ENV__.file))
```

#### SQLite Security Features

Lotus provides database-level read-only protection for SQLite:

- **SQLite 3.8.0+** (2013): Supports `PRAGMA query_only` for database-level write prevention
- **Older versions**: Fall back to regex-based query validation (still secure)

The `PRAGMA query_only` feature provides an additional security layer by preventing INSERT, UPDATE, DELETE, CREATE, DROP, and other write operations at the database engine level, even if they somehow bypassed Lotus's regex validation.

### Mixed Database Environments

You can use different database types for storage and data:

```elixir
config :lotus,
  storage_repo: MyApp.Repo,       # PostgreSQL for Lotus storage
  default_source: "postgres",     # Default data source for queries
  data_sources: %{
    "postgres" => MyApp.Repo,     # PostgreSQL data
    "mysql" => MyApp.MySQLRepo,   # MySQL data
    "sqlite" => MyApp.SqliteRepo  # SQLite data
  }
```

### MySQL

Lotus supports MySQL through the `myxql` adapter. Add the dependency to your `mix.exs`:

```elixir
{:myxql, "~> 0.7"}
```

Configure your MySQL repository:

```elixir
config :my_app, MyApp.MySQLRepo,
  adapter: Ecto.Adapters.MyXQL,
  username: "root",
  password: "mysql",
  hostname: "localhost",
  database: "my_app_dev",
  port: 3306
```

## Session Management & Connection Pool Safety

Lotus implements robust session management to ensure database connections remain in their original state after query execution. This is critical in production environments where connection pooling is used.

### How It Works

Each database adapter uses a **snapshot/restore pattern**:

1. **Before execution**: Lotus snapshots the current session state
2. **During execution**: Lotus applies read-only mode and statement timeouts
3. **After execution**: Lotus automatically restores the original session state

This prevents "connection pool pollution" where one operation's settings affect subsequent operations using the same pooled connection.

### Database-Specific Behavior

#### PostgreSQL
- Uses `SET LOCAL` statements that automatically revert at transaction end
- **No session leakage** - settings are transaction-scoped only
- Minimal overhead with automatic cleanup

#### MySQL
- Snapshots and restores session-level settings:
  - `@@session.transaction_read_only` (access mode)
  - `@@session.transaction_isolation` (isolation level)
  - `@@session.max_execution_time` (statement timeout)
- **Cross-version compatible** - handles MySQL 5.7 vs 8.0+ differences
- Guaranteed restoration using `try/after` blocks

#### SQLite
- Snapshots and restores `PRAGMA query_only` setting
- **Graceful fallback** for SQLite versions < 3.8.0 that don't support the pragma
- Preserves original read-only state if database was already configured as read-only

### Why This Matters

Without proper session management, Lotus queries could leave database connections in unexpected states:

```elixir
# Without session management (problematic):
Lotus.run_statement("SELECT * FROM users")  # Sets read-only mode
MyApp.create_user(%{name: "John"})    # FAILS - connection still read-only!

# With Lotus session management (safe):
Lotus.run_statement("SELECT * FROM users")  # Sets + restores session state
MyApp.create_user(%{name: "John"})    # ✅ Works normally
```

This automatic session management ensures Lotus plays nicely with other parts of your application that share the same database connection pool.

## Lotus Web Setup

[Lotus Web](https://github.com/elixir-lotus/lotus_web) provides a beautiful web interface for Lotus that you can mount directly in your Phoenix application. It's perfect for teams who need visual query tools without the complexity of full BI solutions.

### Installation

Add `lotus_web` to your dependencies:

```elixir
def deps do
  [
    {:lotus, "~> 1.0"},
    {:lotus_web, "~> 1.0"}
  ]
end
```

### Mounting in Your Router

Add Lotus Web to your Phoenix router:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import Lotus.Web.Router

  # ... other routes

  scope "/", MyAppWeb do
    pipe_through [:browser, :require_authenticated_user]  # Always add authentication!
    
    lotus_dashboard "/lotus"
  end
end
```

**⚠️ Security Notice**: Always mount Lotus Web behind authentication. The dashboard provides powerful query capabilities and should only be accessible to authorized users.

### Features

With Lotus Web, your team gets:

- **SQL Editor**: Write queries with syntax highlighting and autocomplete
- **Query Management**: Save, organize, and share queries across your team
- **Schema Explorer**: Browse database tables and columns interactively
- **Multi-Database Support**: Switch between configured repositories
- **Real-time Execution**: LiveView-powered interface with instant feedback
- **Smart Variables**: Use parameterized queries with `{{variable}}` syntax

### Version Compatibility

| Lotus Version | Lotus Web Version |
|---------------|-------------------|
| 1.0.x         | 1.0.x             |
| 0.16.x        | 0.14.x            |

The dependency constraints in `mix.exs` will automatically ensure compatible versions are installed.

### Next Steps

Once installed, visit `/lotus` in your application (or whatever path you mounted it at) to start using the web interface. For more details, see the [Lotus Web documentation](https://github.com/elixir-lotus/lotus_web).

## Troubleshooting

### Common Issues

**Configuration Error**: If you see an `ArgumentError` with `Invalid :lotus config: required :storage_repo option not found, received options: [...]`, Lotus cannot find a storage repository. Check that `config :lotus, storage_repo: MyApp.Repo` is set — and if you are coming from 0.x, that you renamed `:ecto_repo` to `:storage_repo`.

Lotus reads only the v1.0 key names from your application environment, so a
leftover 0.x key is not reported by name — it is simply ignored, and you see the
symptom instead: `:ecto_repo` surfaces as the missing `:storage_repo` above,
while a leftover `:data_repos` leaves `:data_sources` empty and the first query
raises `No data source available for query execution.`. If you see either,
rename `:ecto_repo` to `:storage_repo`, `:data_repos` to `:data_sources`, and
`:default_repo` to `:default_source`. See [Upgrading to v1.0](upgrading-to-v1.md).

**Default Source Not Found**: `Invalid :lotus config: :default_source "x" is not a key in :data_sources` means `:default_source` names a source you did not configure. Lotus checks this at boot rather than on the first query.

**Migration Issues**: If migrations fail, ensure your database is running and your repository configuration is correct.

**Permission Errors**: Lotus requires database access to create tables and execute queries. Ensure your database user has appropriate permissions.

## Next Steps

Now that Lotus is installed, check out the [Getting Started](getting-started.md) guide to create your first query.
