# Contributing to Lotus

Thank you for your interest in contributing to Lotus! This guide will help you get started with development and explain our contribution process.

## Getting Started

### Prerequisites

- Elixir 1.18 or later
- OTP 27 or later
- PostgreSQL 13 or later (for main development database)
- SQLite 3 (for multi-database testing)
- Git

### Development Setup

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/elixir-lotus/lotus.git
   cd lotus
   ```

2. **Install dependencies**
   ```bash
   mix deps.get
   ```

3. **Set up the development databases**
   ```bash
   # Start PostgreSQL (if not running)
   # Then create and migrate the databases
   mix ecto.setup
   ```
   
   This creates:
   - PostgreSQL database (`lotus_dev`) with both Lotus tables and test data tables
   - SQLite database (`lotus_dev.db`) with e-commerce sample data

4. **Run the tests**
   ```bash
   # Run all tests
   mix test
   
   # Run PostgreSQL-specific tests
   mix test --exclude sqlite
   
   # Run SQLite-specific tests  
   mix test --only sqlite
   ```

5. **Start exploring with interactive development**
   ```bash
   iex -S mix
   ```
   
   The development environment automatically starts both PostgreSQL and SQLite repos for testing. You can immediately start experimenting:
   
   ```elixir
   # Test PostgreSQL functionality
   Lotus.run_statement("SELECT COUNT(*) FROM users", [], repo: "postgres")
   
   # Test SQLite functionality
   Lotus.run_statement("SELECT COUNT(*) FROM products", [], repo: "sqlite")
   
   # Create and run queries
   {:ok, query} = Lotus.create_query(%{
     name: "Test Query",
     statement: "SELECT 1 as test"
   })
   Lotus.run_query(query)
   ```

## Architecture Overview

Before making non-trivial changes it helps to understand how Lotus is organized and how a request flows through the system. This section is a map — not an exhaustive reference — and links to the modules you'll most often touch.

### Module Responsibilities

Everything lives under `lib/lotus/`. The library is roughly split into a public API surface, a query pipeline, storage, introspection, and a set of pluggable adapters.

**Public API and lifecycle**

- [`Lotus`](../lib/lotus.ex) — Top-level facade. `run_query/2`, `run_statement/3`, `create_query/1`, schema helpers, and dashboard helpers all entry through here.
- [`Lotus.Supervisor`](../lib/lotus/supervisor.ex) — Boots the configured cache adapter, starts a `Task.Supervisor` (used by dashboard card execution), and compiles the middleware pipeline.
- [`Lotus.Config`](../lib/lotus/config.ex) — Validates and caches application configuration (data sources, cache profiles, visibility rules, AI settings, middleware, etc.).
- [`Lotus.Telemetry`](../lib/lotus/telemetry.ex) — Emits `:telemetry` events for query execution, schema introspection, and cache hits/misses.

**Query pipeline**

- [`Lotus.Runner`](../lib/lotus/runner.ex) — SQL execution engine. Enforces single-statement, applies the read-only deny list, invokes preflight, runs middleware, executes inside a read-only transaction, and applies column-level visibility policies to the result.
- [`Lotus.Preflight`](../lib/lotus/preflight.ex) — Uses `EXPLAIN` (per source) to discover which relations a statement will touch before executing it.
- [`Lotus.Preflight.Relations`](../lib/lotus/preflight/relations.ex) — Process-local staging for relations discovered during preflight so the runner can reuse them when applying column policies.
- [`Lotus.Middleware`](../lib/lotus/middleware.ex) — Plug-style pipeline compiled into `:persistent_term`. Supports `:before_query`, `:after_query`, and `:after_list_*` schema events.
- [`Lotus.Result`](../lib/lotus/result.ex) / [`Lotus.Result.Statistics`](../lib/lotus/result/statistics.ex) — The struct returned from query execution.

**Saved queries, dashboards, and visualizations**

- [`Lotus.Storage`](../lib/lotus/storage.ex) — CRUD for saved queries persisted through the application's `Ecto.Repo`.
- [`Lotus.Storage.Query`](../lib/lotus/storage/query.ex) — Schema for saved queries; builds SQL + params from statement text plus user-supplied variables.
- [`Lotus.Storage.SchemaCache`](../lib/lotus/storage/schema_cache.ex) — ETS-backed cache of column metadata used for type-aware value casting.
- [`Lotus.Storage.TypeCaster`](../lib/lotus/storage/type_caster.ex) / `TypeHandler` — Cast user values into parameters appropriate for the target database. Type mapping is handled by each dialect's `db_type_to_lotus_type/1` callback.
- [`Lotus.Dashboards`](../lib/lotus/dashboards.ex) — CRUD and orchestration for dashboards (cards, filters, filter mappings). Uses the task supervisor to fan out card execution.
- [`Lotus.Viz`](../lib/lotus/viz.ex) — CRUD and validation for per-query visualization configs.
- [`Lotus.Query.Filter`](../lib/lotus/query/filter.ex) / [`Lotus.Query.Sort`](../lib/lotus/query/sort.ex) — Runtime filter/sort structs that the source adapters inject into already-prepared SQL.
- `Lotus.Source.Adapters.Ecto.SQL.*` (`lib/lotus/source/adapters/ecto/sql/`) — Low-level SQL helpers (sanitizer, identifier quoting, filter/sort injectors, validator, transformer).

**Introspection and visibility**

- [`Lotus.Schema`](../lib/lotus/schema.ex) — Lists schemas, lists tables, and inspects table schemas across sources. Automatically applies visibility rules and runs `:after_list_*` middleware.
- [`Lotus.Visibility`](../lib/lotus/visibility.ex) — Two-level visibility (schema → table) plus column policies. Schema visibility takes precedence over table visibility.
- [`Lotus.Visibility.Policy`](../lib/lotus/visibility/policy.ex) — Per-column policy (`:omit`, `{:mask, ...}`, `:error`) that the runner applies to result rows.
- [`Lotus.Visibility.Resolver`](../lib/lotus/visibility/resolver.ex) — Behaviour for plugging in custom visibility resolution; the default lives in [`Lotus.Visibility.Resolvers.Static`](../lib/lotus/visibility/resolvers/static.ex).

**Source adapter abstraction**

- [`Lotus.Source`](../lib/lotus/source.ex) — Public facade for data sources. Provides `resolve!/2`, `source_type/1`, `supports_feature?/2`, `hierarchy_label/1`, and other convenience functions that accept adapter structs, source name strings, or raw repo modules.
- [`Lotus.Source.Adapter`](../lib/lotus/source/adapter.ex) — Behaviour + struct (`%Adapter{name, module, state, source_type}`) that represents a resolved data source. This is what flows through the query pipeline instead of raw repo modules.
- [`Lotus.Source.Adapters.Ecto`](../lib/lotus/source/adapters/ecto.ex) — Macro provider (`use Lotus.Source.Adapters.Ecto, dialect: ...`) and generic fallback adapter for unknown Ecto repos.
- [`Lotus.Source.Adapters.Postgres`](../lib/lotus/source/adapters/postgres.ex) / [`MySQL`](../lib/lotus/source/adapters/mysql.ex) / [`SQLite3`](../lib/lotus/source/adapters/sqlite.ex) — Per-dialect adapter modules. Each uses `use Lotus.Source.Adapters.Ecto` with its corresponding dialect.
- [`Lotus.Source.Adapters.Ecto.Dialect`](../lib/lotus/source/adapters/ecto/dialect.ex) — Behaviour for SQL-dialect-specific callbacks (transaction handling, identifier quoting, introspection queries, type mapping, etc.).
- [`Lotus.Source.Adapters.Ecto.Dialects.Postgres`](../lib/lotus/source/adapters/ecto/dialects/postgres.ex) / [`MySQL`](../lib/lotus/source/adapters/ecto/dialects/mysql.ex) / [`SQLite3`](../lib/lotus/source/adapters/ecto/dialects/sqlite.ex) / [`Default`](../lib/lotus/source/adapters/ecto/dialects/default.ex) — Dialect implementations.
- [`Lotus.Source.Resolver`](../lib/lotus/source/resolver.ex) / [`Lotus.Source.Resolvers.Static`](../lib/lotus/source/resolvers/static.ex) — Behaviour and default implementation for resolving a name/module into an `%Adapter{}`. Alternative resolvers can come from registries or external services.
- [`Lotus.Normalizer.Postgres`](../lib/lotus/normalizer/postgres.ex) / [`Lotus.Normalizer.MySQL`](../lib/lotus/normalizer/mysql.ex) — Normalize driver-specific result shapes into the `Lotus.Result` format.

**Caching**

- [`Lotus.Cache`](../lib/lotus/cache.ex) — Facade that dispatches to the configured cache adapter and emits telemetry. Supports namespaced keys, TTL, and tag-based invalidation.
- [`Lotus.Cache.Adapter`](../lib/lotus/cache/adapter.ex) — Behaviour for cache backends.
- [`Lotus.Cache.ETS`](../lib/lotus/cache/ets.ex) / [`Lotus.Cache.Cachex`](../lib/lotus/cache/cachex.ex) — Built-in backends. ETS is the zero-dependency default; Cachex is the advanced option.
- [`Lotus.Cache.Key`](../lib/lotus/cache/key.ex) — Stable key derivation from SQL, parameters, adapter name, and search path.

**Export and AI**

- [`Lotus.Export`](../lib/lotus/export.ex) — Converts `Lotus.Result` to CSV/JSON/JSONL, streams large CSV exports, and ZIPs a full dashboard export.
- [`Lotus.AI`](../lib/lotus/ai.ex) — Public AI surface (`generate_query/1`, `explain_query/2`, `optimize_query/2`).
- [`Lotus.AI.SQLGenerator`](../lib/lotus/ai/sql_generator.ex), [`QueryExplainer`](../lib/lotus/ai/query_explainer.ex), [`QueryOptimizer`](../lib/lotus/ai/query_optimizer.ex) — Request orchestration for each AI capability.
- [`Lotus.AI.Conversation`](../lib/lotus/ai/conversation.ex) — Multi-turn conversation state used for iterative refinement.
- [`Lotus.AI.Actions`](../lib/lotus/ai/actions.ex) and `lib/lotus/ai/actions/` — Tool definitions the LLM can call (schema listing, column value sampling, SQL validation/execution).
- `Lotus.AI.Prompts.*` (`lib/lotus/ai/prompts/`) — Prompt templates for SQL generation, explanation, optimization, and variable inference.
- [`Lotus.AI.SchemaOptimizer`](../lib/lotus/ai/schema_optimizer.ex) — Trims schema context before it is sent to the LLM.

### Query Execution Pipeline

When you call `Lotus.run_query(query, opts)` the request flows through roughly the following stages. `Lotus.run_statement/3` skips the variable and storage stages but shares the rest.

```
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.run_query / Lotus.run_statement                                │
│  • Merge variable defaults + opts[:vars]                             │
│  • Storage.Query.compile/2 → {:ok, %Statement{}}                     │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Source.resolve!/2                                              │
│  • Configured resolver → %Lotus.Source.Adapter{}                     │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Dynamic SQL shaping (per-source via Lotus.Source)                    │
│  • apply_filters/3 (Lotus.Query.Filter)                              │
│  • apply_sorts/2   (Lotus.Query.Sort)                                │
│  • windowed pagination (limit/offset/count)                          │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Cache.get_or_store/4                                           │
│  • Key: sql + params + adapter name + search_path                    │
│  • Tags: ["query:<id>", "repo:<name>", ...user tags]                 │
│  • Hit  → return cached Result                                       │
│  • Miss → run the fetcher below                                      │
└─────────────────────────────────────────────────────────────────────┘
                               │ miss / :bypass / :refresh
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Lotus.Runner.run_statement                                           │
│  1. assert_single_statement/1                                        │
│  2. assert_not_denied/2 (skipped when read_only: false)              │
│  3. Lotus.Preflight.authorize (EXPLAIN + visibility check)           │
│  4. Middleware.run(:before_query, _)                                 │
│  5. Adapter.transaction (read-only) → Adapter.execute_query          │
│  6. Column policy enforcement (omit / mask / error)                  │
│  7. Middleware.run(:after_query, _)                                  │
│  8. Telemetry start/stop/exception                                   │
└─────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                          Lotus.Result
```

A few notes on the pipeline:

- **Variable binding** happens inside `Lotus.Storage.Query.compile/2`, which also consults `Lotus.Storage.SchemaCache` for type-aware casting of user-supplied values.
- **Filters and sorts** are injected through the source adapter, not concatenated naively — see `Lotus.SQL.FilterInjector` and `Lotus.SQL.SortInjector`.
- **Windowed pagination** rewrites the SQL to fetch a page and (optionally) issue a separate `COUNT(*)` for the exact total.
- **Caching** is optional. When no cache adapter is configured, `Lotus.Cache` is a pass-through and the fetcher always runs.
- **Preflight** issues `EXPLAIN` against the target source. The relations it discovers are stashed in `Lotus.Preflight.Relations` so the runner can look up column visibility policies without re-parsing the SQL.
- **Middleware** runs after preflight and before the actual execution — halting the pipeline from a `:before_query` plug yields `{:error, reason}` to the caller.

### Schema Introspection Flow

Schema calls follow a simpler path but share the same adapter and middleware infrastructure:

```
Lotus.Schema.list_schemas / list_tables / get_table_schema
  │
  ▼
Lotus.Source.resolve!/2         (→ %Adapter{})
  │
  ▼
Lotus.Cache.get_or_store         (optional, keyed by repo + args)
  │
  ▼
Adapter dispatch → source-specific introspection query
  │
  ▼
Lotus.Visibility filtering       (schema > table > column)
  │
  ▼
Middleware.run(:after_list_schemas | :after_list_tables | ...)
  │
  ▼
Telemetry.schema_introspection_stop
```

Column metadata discovered during `get_table_schema/2` is additionally cached in `Lotus.Storage.SchemaCache`, which is what powers type-aware variable casting when queries run.

### Adapter Patterns

Lotus has four pluggable extension points. Each is a behaviour plus a default implementation, so you can swap any of them without forking the library.

| Extension point            | Behaviour                                     | Default                                  |
|----------------------------|-----------------------------------------------|------------------------------------------|
| Data source adapter        | `Lotus.Source.Adapter`                        | `Lotus.Source.Adapters.{Postgres,MySQL,SQLite3,Ecto}` |
| Source resolver            | `Lotus.Source.Resolver`                       | `Lotus.Source.Resolvers.Static`          |
| Visibility resolver        | `Lotus.Visibility.Resolver`                   | `Lotus.Visibility.Resolvers.Static`      |
| Cache adapter              | `Lotus.Cache.Adapter`                         | `Lotus.Cache.ETS` (or `Lotus.Cache.Cachex`) |

Design notes for adapter authors:

- **Source adapters** carry state in the `%Adapter{}` struct itself (e.g. an Ecto repo module) so the runner never closes over the raw connection. Every introspection callback returns `{:ok, _} | {:error, _}`.
- **Source resolvers** let you replace the static `data_sources` list with a dynamic registry (database-backed tenants, feature-flagged sources, etc.).
- **Visibility resolvers** let you compute schema/table/column policies from external sources instead of config — useful when rules live in a multi-tenant database.
- **Cache adapters** must implement `get_or_store/4`, `put/4`, and `invalidate_tags/1`. ETS is the zero-dependency option; Cachex is recommended when you need distributed caching or richer stats.

### Design Principles

A few opinions run through the codebase; preserving them when you contribute will make review much easier.

1. **Read-only by default, with defense in depth.** Destructive statements are blocked by (a) a regex deny list, (b) preflight authorization using `EXPLAIN`, and (c) a database-level read-only transaction. Each layer exists because the previous one can be bypassed in some edge case. Opting out (`read_only: false`) is a deliberate, explicit flag.
2. **Pluggable, not hardcoded.** Sources, resolvers, caches, and visibility all go through behaviours. Avoid pattern-matching on concrete modules inside the query pipeline — dispatch through the adapter.
3. **Visibility is two-level plus column-aware.** Schema visibility is checked before table visibility, and column policies (omit/mask/error) run inside the runner after the result comes back. Any new introspection path must respect all three.
4. **Session state is scoped and explicit.** Per-request state like statement timeouts and search paths is set by the source adapter at the start of a transaction; there is no hidden global state. `Lotus.Preflight.Relations` is the one place we use the process dictionary, and it's scrubbed per call.
5. **Type-aware caching.** Query results and schema metadata are cached separately. Result caches are keyed on `sql + params + adapter + search_path` and tagged for targeted invalidation. Column metadata lives in `Lotus.Storage.SchemaCache` so value casting doesn't require re-introspection.
6. **Observability is first-class.** Every meaningful operation emits `[:lotus, ...]` telemetry events. New features should do the same (look at `Lotus.Telemetry` for helpers).
7. **Middleware is the extension seam for cross-cutting concerns.** Auditing, access control, and per-tenant overrides belong in middleware plugs — not in the runner itself.

### Where to Look Next

- New to the pipeline? Start in [`Lotus`](../lib/lotus.ex) (`run_query/2`) and follow the calls into [`Lotus.Runner`](../lib/lotus/runner.ex).
- Working on a new database? See the [Source Adapters guide](source-adapters.md) and mimic [`Lotus.Source.Adapters.Ecto.Dialects.Postgres`](../lib/lotus/source/adapters/ecto/dialects/postgres.ex).
- Working on caching? [`Lotus.Cache`](../lib/lotus/cache.ex) and [`Lotus.Cache.ETS`](../lib/lotus/cache/ets.ex) are the smallest self-contained example.
- Working on visibility or auditing? Start in [`Lotus.Visibility`](../lib/lotus/visibility.ex) and [`Lotus.Middleware`](../lib/lotus/middleware.ex).
- Working on AI features? Begin with [`Lotus.AI`](../lib/lotus/ai.ex) and follow the calls into `lib/lotus/ai/`.

## Development Workflow

### Making Changes

1. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Follow the existing code style
   - Add tests for new functionality
   - Update documentation as needed

3. **Test your changes**
   ```bash
   # Run all tests
   mix test

   # Run specific test files
   mix test test/lotus/storage_test.exs

   # Run with coverage
   mix test --cover
   ```

4. **Ensure code quality**
   ```bash
   # Format code
   mix format

   # Run static analysis
   mix dialyzer

   # Run linting (if available)
   mix lint
   ```

5. **Commit your changes**
   ```bash
   git add .
   git commit -m "Add feature: your feature description"
   ```

6. **Push and create a pull request**
   ```bash
   git push origin feature/your-feature-name
   ```

### Code Style Guidelines

#### Elixir Style

- Use `mix format` to ensure consistent formatting
- Keep lines under 100 characters when possible
- Use descriptive variable and function names

#### Documentation

- All public functions must have `@doc` strings
- Use `@spec` for type specifications
- Include examples in documentation when helpful

```elixir
@doc """
Creates a new query with the given attributes.

## Parameters

  * `attrs` - A map containing query attributes

## Returns

  * `{:ok, query}` - Successfully created query
  * `{:error, changeset}` - Validation or database errors

## Examples

    iex> Lotus.create_query(%{name: "User Count", statement: "SELECT COUNT(*) FROM users"})
    {:ok, %Lotus.Storage.Query{}}

"""
@spec create_query(map()) :: {:ok, Query.t()} | {:error, Ecto.Changeset.t()}
def create_query(attrs) do
  # Implementation
end
```

#### Testing

- Write tests for all new functionality
- Use descriptive test names
- Group related tests with `describe` blocks
- Include both happy path and error case tests

```elixir
describe "create_query/1" do
  test "creates query with valid attributes" do
    attrs = %{name: "Test Query", statement: "SELECT 1"}

    assert {:ok, query} = Lotus.create_query(attrs)
    assert query.name == "Test Query"
  end

  test "returns error with invalid attributes" do
    attrs = %{name: "", statement: "SELECT 1"}

    assert {:error, changeset} = Lotus.create_query(attrs)
    assert "can't be blank" in errors_on(changeset).name
  end
end
```

## Types of Contributions

### Bug Reports

When reporting bugs, please include:

- **Environment**: Elixir version, OTP version, database type and version
- **Steps to reproduce**: Clear, step-by-step instructions
- **Expected behavior**: What you expected to happen
- **Actual behavior**: What actually happened
- **Error messages**: Full error messages and stack traces
- **Code samples**: Minimal code that reproduces the issue

### Feature Requests

For new features, please include:

- **Problem description**: What problem does this solve?
- **Proposed solution**: How would you like it to work?
- **Alternatives considered**: What other approaches did you consider?
- **Examples**: Show how the feature would be used

### Code Contributions

We welcome contributions of all sizes! Here are some areas where help is especially appreciated:

#### Good First Issues

- Documentation improvements
- Additional test coverage
- Small bug fixes
- Code formatting and style improvements

#### Medium Complexity

- New configuration options
- Performance optimizations
- Additional query validation features
- Enhanced error messages

#### Advanced Features

- Additional cache backends (Redis, Memcached, distributed caching)
- Cache statistics and telemetry integration (`Lotus.Cache.stats()`)
- Query performance monitoring and metrics
- Advanced security features
- Table visibility rule enhancements

## Pull Request Process

### Before Submitting

1. **Check existing issues**: Make sure your change isn't already being worked on
2. **Discuss large changes**: Open an issue to discuss major features or breaking changes
3. **Update documentation**: Include relevant documentation updates
4. **Add tests**: Ensure your changes are well-tested
5. **Follow conventions**: Match the existing code style and patterns

### Pull Request Template

When creating a pull request, please include:

```markdown
## Description
Brief description of the changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Refactoring

## Testing
- [ ] Tests pass locally
- [ ] New tests added for functionality
- [ ] Documentation updated

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Corresponding documentation updated
```

### Review Process

1. **Automated checks**: CI will run tests and style checks
2. **Code review**: Maintainers will review your changes
3. **Feedback**: Address any requested changes
4. **Approval**: Once approved, changes will be merged

## Development Guidelines

### Database Changes

When making changes that affect the database:

1. **Create migrations**: Use `Lotus.Migrations` for schema changes
2. **Test migrations**: Ensure migrations work both up and down on PostgreSQL and SQLite
3. **Update version**: Bump the migration version appropriately
4. **Test multi-database**: Verify changes work with both PostgreSQL and SQLite adapters

### Testing Multi-Database Features

When working on features that affect multiple database types:

```bash
# Test against PostgreSQL
mix test --exclude sqlite

# Test against SQLite  
mix test --only sqlite

# Test table visibility across adapters
mix test test/lotus/visibility_test.exs

# Test data source functionality
mix test test/lotus/data_source_test.exs
```

### Caching Features

When working on caching-related features:

```bash
# Test cache functionality
mix test test/lotus/cache_test.exs

# Test cache integration
mix test test/integration/caching_test.exs

# Test ETS adapter specifically
mix test test/lotus/cache/ets_test.exs
```

**Contributing New Cache Backends:**

To implement a new cache backend (Redis, Memcached, etc.):

1. **Implement the behaviour**: Create a module that implements `Lotus.Cache`
2. **Required callbacks**: `get_or_store/4`, `put/4`, `invalidate_tags/1`
3. **Add tests**: Create comprehensive tests following the ETS adapter pattern
4. **Add to documentation**: Update configuration guides and examples
5. **Consider dependencies**: Keep external dependencies optional when possible

**Cache Telemetry and Statistics:**

The caching system would benefit from:
- Cache hit/miss ratios
- Memory usage tracking
- TTL effectiveness metrics
- Tag invalidation statistics

### API Changes

For changes to the public API:

1. **Backward compatibility**: Avoid breaking existing functionality
2. **Deprecation process**: Deprecate before removing functionality
3. **Documentation**: Update all relevant documentation
4. **Examples**: Update examples in guides

### Performance Considerations

- **Benchmark changes**: Use `:timer.tc/1` or benchmarking tools for performance-critical changes
- **Memory usage**: Be mindful of memory allocation in hot paths
- **Database queries**: Optimize query patterns and avoid N+1 queries

## Release Process

### Versioning

Lotus follows [Semantic Versioning](https://semver.org/):

- **Major (1.0.0)**: Breaking changes
- **Minor (0.2.0)**: New features, backward compatible
- **Patch (0.0.1)**: Bug fixes, backward compatible

### Changelog

All notable changes are documented in `CHANGELOG.md`:

- **Added**: New features
- **Changed**: Changes in existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security improvements

## Community Guidelines

### Code of Conduct

We are committed to providing a welcoming and inspiring community for all. Please:

- **Be respectful**: Treat everyone with respect and kindness
- **Be inclusive**: Welcome newcomers and help them get started
- **Be constructive**: Provide helpful feedback and suggestions
- **Be patient**: Remember that everyone has different experience levels

### Communication

- **GitHub Issues**: For bug reports, feature requests, and discussions
- **Pull Requests**: For code contributions and reviews
- **Discussions**: For general questions and community interaction

### Getting Help

If you need help:

1. **Check the documentation**: Start with the guides and API documentation
2. **Search existing issues**: Your question might already be answered
3. **Ask in discussions**: Use GitHub Discussions for general questions
4. **Open an issue**: For specific bugs or feature requests

## Recognition

Contributors are recognized in:

- **CONTRIBUTORS.md**: List of all contributors
- **Release notes**: Acknowledgment in release announcements
- **Documentation**: Attribution for significant documentation contributions

## License

By contributing to Lotus, you agree that your contributions will be licensed under the same license as the project (MIT License).

---

Thank you for contributing to Lotus! Your help makes this project better for everyone.
