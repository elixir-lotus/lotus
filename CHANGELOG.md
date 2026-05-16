# Changelog

## [Unreleased]

## [0.16.6] - 2026-05-16

### Fixed

- **FIX:** `Lotus.Cache.ETS` is now a proper `GenServer` so applications using the ETS cache can shut down cleanly. Previously the adapter's `start_link/1` returned `{:ok, self()}` and spawned a janitor process that never trapped exits, causing `Application.stop/1` and `System.stop/0` to hang until the BEAM forced shutdown (#219)

## [0.16.5] - 2026-05-02

### Fixed

- **FIX:** `Lotus.Migrations` now maps the Ecto MyXQL adapter to the Lotus MySQL migration adapter, so MySQL hosts can run `Lotus.Migrations.up/0` and `down/0` correctly (#223)

## [0.16.4] - 2026-03-10

### Fixed

- **FIX:** Remove `@derive {Lotus.JSON.encoder(), ...}` from `Result` struct that caused `{:invalid_byte, 255}` crashes when query results contained raw UUID binaries from PostgreSQL. Added `Result.to_encodable/1` for explicit JSON-safe serialization with value normalization. Regression introduced in v0.16.0 (#135)

### Changed

- **REFACTOR:** Extract `Lotus.Normalizer` protocol from `Lotus.Export.Normalizer` into a top-level module for general-purpose value normalization (UUID binaries, Dates, Decimals, Postgrex/MyXQL types). `Lotus.Export.Value` now delegates to `Lotus.Normalizer`. **`Lotus.Export.Normalizer` has been removed** — if you implemented this protocol for custom types, implement `Lotus.Normalizer` instead.
- **NEW:** Added `guides/middleware.md` documentation for the middleware pipeline

## [0.16.3] - 2026-03-08

### Fixed

- **FIX:** Accept date-only strings (e.g. `"2025-07-01"`) when casting to `:datetime` type — the `TypeCaster` now falls back to parsing as a `Date` and converts to midnight (`~N[2025-07-01 00:00:00]`) instead of raising "Invalid datetime format". This fixes a regression where query variables typed as `:date` were overridden by auto-detected `:datetime` column types from the database

## [0.16.2] - 2026-03-08

### Fixed

- **FIX:** Strip trailing semicolons from SQL queries before wrapping them in CTEs in `FilterInjector` and `SortInjector` — queries ending with `;` (e.g. CTE queries) would trigger the "Only a single statement is allowed" error when filters or sorts were applied
- **NEW:** Extract shared `Lotus.SQL.Sanitizer` module for SQL string cleanup helpers used by injectors

## [0.16.1] - 2026-03-08

### Fixed

- **FIX:** Wrap raw LLM provider errors in `Lotus.AI.Error` domain exceptions before returning them to callers — raw errors from ReqLLM (containing API endpoints, stack traces, provider metadata) are now logged server-side and replaced with user-safe error structs: `RateLimitError`, `AuthenticationError`, `ServerError`, `TimeoutError`, `ServiceError`

## [0.16.0] - 2026-03-08

### Added

- **NEW:** Middleware pipeline for query execution and schema discovery hooks (`Lotus.Middleware`)
  - [Plug](https://hexdocs.pm/plug/readme.html)-style `init/1` + `call/2` callbacks with `{:cont, payload}` / `{:halt, reason}` control flow
  - Query events: `:before_query`, `:after_query`
  - Discovery events: `:after_list_schemas`, `:after_list_tables`, `:after_get_table_schema`, `:after_list_relations`
  - Compiled to `:persistent_term` at startup for zero-overhead runtime dispatch
  - Opaque `:context` option allows user data to be provided to middleware (e.g. current user) through all middleware
- **NEW:** Result filtering via `:filters` option on `Lotus.run_query/2` and `Lotus.run_sql/3`
  - Pass a list of `Lotus.Query.Filter` structs to apply WHERE conditions on top of any query
  - Filters are applied by wrapping the original query in a CTE, so they work safely with any SQL complexity (joins, subqueries, unions, etc.)
  - Supports operators: `=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `IS NULL`, `IS NOT NULL`
  - Source-aware: each database adapter (PostgreSQL, MySQL, SQLite) handles its own identifier quoting via new `quote_identifier/1` and `apply_filters/2` callbacks on `Lotus.Source`
  - New `Lotus.Query.Filter` struct for source-agnostic filter representation
  - New `Lotus.SQL.FilterInjector` shared helper for SQL-based sources
- **NEW:** Result sorting via `:sorts` option on `Lotus.run_query/2` and `Lotus.run_sql/3`
  - Pass a list of `Lotus.Query.Sort` structs to apply ORDER BY on top of any query
  - Sorts are applied by wrapping the original query in a CTE, so they work safely with any SQL complexity (joins, subqueries, unions, existing ORDER BY, etc.)
  - Supports `:asc` and `:desc` directions
  - Source-aware: each database adapter handles its own identifier quoting via new `apply_sorts/2` callback on `Lotus.Source`
  - New `Lotus.Query.Sort` struct for source-agnostic sort representation
  - New `Lotus.SQL.SortInjector` shared helper for SQL-based sources
- **FIX:** AI SQL generation now validates plain SQL responses (without `` ```sql `` code blocks) against the database using EXPLAIN before rejecting them — valid SQL is accepted, conversational text is still rejected as `{:error, {:unable_to_generate, content}}` ([#127](https://github.com/typhoonworks/lotus/issues/127))
- **NEW:** `Lotus.SQL.Validator` — validates SQL syntax against the database without executing, using EXPLAIN. Neutralizes `{{var}}` and `[[...]]` template syntax before validation
- **NEW:** `Lotus.AI.Actions.ValidateSQL` — AI tool action that lets the LLM validate its SQL against the database before returning it
- **NEW:** `Lotus.Variables` — universal utilities for `{{variable}}` template syntax: `regex/0`, `extract_names/1`, `neutralize/2`. Consolidates the variable regex previously duplicated across `OptionalClause`, `Query`, and `QueryOptimizer`
- **NEW:** `Lotus.SQL.OptionalClause.strip_brackets/1` — strips `[[` / `]]` brackets unconditionally, keeping inner content. Used by `Validator` and `QueryOptimizer` for preparing SQL for EXPLAIN
- **FIX:** `Lotus.Source.param_placeholder/4` and `Lotus.Source.limit_offset_placeholders/3` no longer hardcode a fallback to PostgreSQL when the repo is `nil` — they now resolve via the configured default data repo
- **NEW:** Optional variables with [[ ]] syntax
- **NEW:** Column-level statistics for query results (`Lotus.Result.Statistics`)
  - Computes per-column statistics from in-memory result sets without additional database queries
  - Numeric columns: min, max, avg, median, sum, distinct count, null count/percentage, histogram (10 bins)
  - String columns: distinct count, top values with counts, null count/percentage, min/max length
  - Temporal columns: earliest, latest, null count/percentage, distribution over time
  - Supports `Date`, `DateTime`, `NaiveDateTime`, `Time`, `Decimal`, and standard Elixir types
  - Public API: `compute/2` (single column), `compute_all/1` (all columns), `detect_column_type/2`
- **NEW:** Telemetry integration for observability
  - Query execution events: `[:lotus, :query, :start]`, `[:lotus, :query, :stop]`, `[:lotus, :query, :exception]`
  - Cache operation events: `[:lotus, :cache, :hit]`, `[:lotus, :cache, :miss]`, `[:lotus, :cache, :put]`
  - Schema introspection events: `[:lotus, :schema, :introspection, :start]`, `[:lotus, :schema, :introspection, :stop]`
  - New `Lotus.Telemetry` module with event reference documentation
  - Telemetry guide with setup instructions and LiveDashboard integration example
- **NEW:** AI-powered query optimization suggestions (`Lotus.AI.suggest_optimizations/1`)
  - Analyzes SQL queries and execution plans to suggest performance improvements
  - Returns categorized suggestions with type (index/rewrite/schema/configuration) and impact level (high/medium/low)
  - Uses EXPLAIN plan analysis combined with AI to provide actionable recommendations
  - Schema-aware: uses `get_table_schema` tool to inspect relevant tables
  - Handles Lotus-specific `{{variable}}` and `[[optional clause]]` syntax — sanitizes before EXPLAIN, preserves original SQL for AI analysis
- **NEW:** AI-powered query explanation (`Lotus.AI.explain_query/1`)
  - Get plain-language explanations of what a SQL query does
  - Supports explaining a full query or a selected fragment (e.g., a single JOIN, a HAVING clause)
  - Fragment mode sends the full query as context so even isolated terms are explained accurately
  - Understands Lotus-specific `{{variable}}` and `[[optional clause]]` syntax and explains their runtime behavior
  - Schema-aware: uses `get_table_schema` tool to inspect relevant tables for richer explanations
- **NEW:** `Lotus.AI.Action` behaviour and `Lotus.AI.Tool.from_action/2` for declarative AI tool definitions
  - Define tools as modules with `name/0`, `description/0`, `schema/0` (NimbleOptions), and `run/2` callbacks
  - `Tool.from_action/2` converts action modules to `ReqLLM.tool()` structs with automatic JSON Schema generation
  - Supports parameter binding via `:bind` option to hide/pre-fill parameters from the LLM
  - Built-in actions: `ListSchemas`, `ListTables`, `GetTableSchema`, `GetColumnValues`, `ListDataSources`, `ExecuteSQL`
- **NEW:** `Lotus.AI.Tool.run/4` — shared tool-calling loop that replaces duplicated loops in `SQLGenerator`, `QueryOptimizer`, and `QueryExplainer`
- **NEW:** `Lotus.SQL.Identifier` — shared module for SQL identifier validation and parsing
  - Validates identifiers against `[a-zA-Z_][a-zA-Z0-9_]*` to prevent SQL injection in interpolated values
  - `validate_identifier!/2` and `validate_search_path!/1` guard Postgres `search_path` and SQLite `PRAGMA` interpolations
  - Consolidates `parse_table_name/1`, `validate_identifier/2`, and `validate_table_parts/2` previously in `Lotus.AI.Actions.Helpers`
- Added `JSON.Encoder` derive for `Lotus.Result` struct

### Breaking

- Replaced `langchain` dependency with `req_llm` for AI query generation
  - Removed provider abstraction layer (`Lotus.AI.Provider` behaviour, `Lotus.AI.ProviderRegistry`, and individual provider modules)
  - New `Lotus.AI.SQLGenerator` module replaces `Lotus.AI.Providers.Core`
  - AI config simplified from separate `provider` + `model` keys to a single `model` key using ReqLLM's `"provider:model"` format (e.g., `"openai:gpt-4o"`, `"anthropic:claude-sonnet-4-5-20250514"`)
  - All providers supported by ReqLLM are now available (OpenAI, Anthropic, Google, Groq, Mistral, and more)
  - `generate_query/1` and `generate_query_with_context/1` return `model` (full model string) instead of `provider`

### Changed

- Refactored `SQLGenerator`, `QueryExplainer`, and `QueryOptimizer` to use `Action` modules + `Tool.from_action/2` instead of inline tool construction
- Replaced duplicated tool-calling loops in each AI module with shared `Tool.run/4`
- Replaced per-module usage normalization with shared `Tool.normalize_usage/1`
- Removed `Lotus.AI.Tools.SchemaTools` — replaced by `Lotus.AI.Actions.*` modules

## [0.15.0] - 2026-03-05

### Added

- **NEW:** `read_only: false` option for `run_sql` — disables the application-level deny list, allowing write queries (INSERT, UPDATE, DELETE, DDL). Single-statement validation and visibility rules still apply.
- **NEW:** AI-generated query variable configurations alongside SQL
  - LLM can now produce `{{variable}}` placeholders with full variable metadata (type, widget, label, default, list, static_options, options_query)
  - System prompt teaches the LLM when and how to generate variables (only on explicit user request, never proactively)
  - Smart options strategy: `static_options` via `get_column_values()` for small cardinality, `options_query` for dynamic/large sets
  - `extract_variables/1` parser for ```` ```variables ```` JSON blocks with normalization (type validation, widget/list defaults, nil stripping)
  - `extract_response/1` unified extractor combining SQL and variable extraction for providers
  - All providers (OpenAI, Anthropic, Gemini) return `variables` in their response map
  - `generate_query/1` and `generate_query_with_context/1` now include `variables` in the result
  - Conversation history preserves and formats variable context across multi-turn exchanges

### Changed

- `Lotus.AI.Provider.response` type now includes a `variables` field
- `Conversation.add_assistant_response/4` accepts an optional `variables` parameter (defaults to `[]`)
- Providers use `SQLGeneration.extract_response/1` instead of `extract_sql/1` for response parsing
- Fixed cache adapter constraint that prevented custom cache adapters from being used

### Dependencies

- Bumped `langchain` from 0.5.2 to 0.6.0
- Bumped `ecto_sql` from 3.13.4 to 3.13.5
- Bumped `credo` from 1.7.16 to 1.7.17

## [0.14.0] - 2026-02-16

### Added

- **NEW:** List variable support for multi-value query parameters (e.g., `IN (...)` clauses)
  - Variables with `list: true` expand to multiple SQL placeholders at execution time
  - Correct parameter index sequencing when mixing list and scalar variables
  - Per-element type casting for list values (e.g., `:number` casts each element individually)
  - Automatic normalization of comma-separated strings into lists (e.g., `"US, UK, DE"` → `["US", "UK", "DE"]`)
  - Support for all database adapters (PostgreSQL `$1, $2, $3`, MySQL/SQLite `?, ?, ?`)
  - Validation that list variables contain at least one value
  - Added `list` boolean field to `QueryVariable` schema (defaults to `false`)

## [0.13.0] - 2026-02-10

### Added

- **NEW:** Long-running conversation support for AI-powered query generation
  - Multi-turn conversations with context retention across messages
  - Conversational refinement of generated queries based on user feedback
  - Enhanced error detection and query optimization capabilities
  - Support for iterative query improvements without starting from scratch
  - Replaces previous "fire and forget" single-request model with stateful conversations

### Changed

- **BREAKING:** Minimum Elixir version bumped from 1.16 to 1.17 (required by `langchain` dependency)

## [0.12.0] - 2026-02-10

### Added

- **NEW (EXPERIMENTAL):** AI-powered SQL query generation from natural language
  - Support for OpenAI (GPT-4, GPT-4o), Anthropic (Claude), and Google Gemini models
  - Schema-aware query generation with tool-based introspection
  - Automatic discovery of schemas, tables, columns, and enum values
  - Multi-turn conversations with LLM for complex queries
  - Respects Lotus visibility rules - AI sees only what users see
  - Configuration-based setup (no database changes required)
  - `Lotus.AI.generate_query/1` API for programmatic access
  - Four introspection tools: `list_schemas()`, `list_tables()`, `get_table_schema()`, `get_column_values()`
  - Provider-agnostic architecture with shared tool implementations
  - Disabled by default - requires explicit configuration
  - See "AI Query Generation" section in README for setup instructions

### Changed

- Added `langchain` as a required dependency (needed for AI features)
- AI features are opt-in via configuration - no impact if not configured

## [0.11.0] - 2026-02-04

### Added

- **NEW:** Dashboard support for combining multiple queries into interactive, shareable views
  - Create dashboards with cards arranged in a 12-column grid layout
  - Card types: query results, text, headings, and links
  - Dashboard-level filters that map to query variables across cards
  - Public sharing via secure tokens
  - Parallel query execution with configurable timeouts
  - ZIP export with CSV per card
- **NEW:** Automatic type casting system for query variables with intelligent column type detection
- **NEW:** `Lotus.Storage.TypeHandler` behaviour for implementing custom database type handlers
- **NEW:** Custom type handler registry system via `Application.get_env(:lotus, :type_handlers)`
- **NEW:** Support for complex PostgreSQL types:
  - Array types (`integer[]`, `text[]`, etc.) with element-wise casting
  - Enum types (`USER-DEFINED` types) with pass-through handling
  - Composite types with JSON input support
  - PostgreSQL array format parsing (supports both `{1,2,3}` and `[1,2,3]` formats)
- **NEW:** `Lotus.Storage.SchemaCache` for caching column type information
- **NEW:** `Lotus.Storage.TypeMapper` for mapping database types to Lotus internal types
- **NEW:** `Lotus.Storage.TypeCaster` for converting string values to database-native formats
- **NEW:** `Lotus.Storage.VariableResolver` for automatic variable-to-column binding detection
- Added support for `:time` type with ISO8601 time parsing (e.g., "10:30:00")
- Added graceful fallback handling when schema cache is unavailable (defaults to `:text` type)
- Added "cast only when needed" optimization - text and enum types pass through without casting
- Added comprehensive logging for type detection failures (debug/warning levels)
- Added support for schema-qualified table names in automatic type detection (e.g., `public.users`)
- Added custom type handler validation to ensure handlers implement required callbacks

### Changed

- Enhanced query variable system to automatically detect column types from database schema
- Enhanced type casting to prioritize automatic detection for non-text types, falling back to manual types
- Improved error messages for type casting failures with helpful format hints

## [0.10.0] - 2026-01-05

### Added

- **NEW:** `Lotus.Cache.Cachex` adapter for local or distributed in-memory caching using [Cachex](https://hexdocs.pm/cachex/)
- **NEW:** Query visualization storage with opaque config (validation delegated to consumers)
- **NEW:** `Lotus.Viz` module for visualization CRUD operations
- **NEW:** Visualization config validation against query results
- Added `list_visualizations/1`, `create_visualization/2`, `update_visualization/2`, `delete_visualization/1` delegations to main `Lotus` module
- Added `validate_visualization_config/2` for validating visualization configs against result columns
- **NEW:** Column-level visibility rules with masking support (`:allow`, `:omit`, `:mask`, `:error`)
- **NEW:** `Lotus.Visibility.Policy` module for policy creation and validation
- **NEW:** `Lotus.Preflight.Relations` module for cleaner preflight relation management

### Changed

- **INTERNAL:** Comprehensive Credo-based code quality improvements:
  - Eliminated deeply nested functions by extracting helper functions
  - Reduced cyclomatic complexity across multiple modules
  - Replaced `unless/else` patterns with cleaner `if/else` structures
  - Converted single-clause `with` statements to more appropriate `case` statements
  - Refactored complex `cond` statements to use pattern matching
  - Improved function naming conventions (e.g., `is_repo_module?` → `repo_module?`)
  - Configured selective exclusions for `MapJoin` warnings where readability is prioritized
  - Enhanced code maintainability and testability without changing public APIs

## [0.9.2] - 2025-09-07

- Added `Lotus.Export.stream_csv/2` to export the full result page by page

## [0.9.1] - 2025-09-05

### Added

- Added windowed pagination capped at max 1000 pages to prevent performance degradation

## [0.9.0] - 2025-09-04

### Added
- Added `num_rows`, `duration_ms`, and `command` attributes to `Lotus.Result` struct returned by query execution
- Added comprehensive error messages for type conversion failures in query variables
- Added support for both integer and float parsing in `:number` type variables

### Changed
- **BREAKING:** Enhanced `QueryVariable.static_options` to support multiple input formats but normalize output to `%{value: String.t(), label: String.t()}` maps

### Fixed
- Fixed type casting errors that previously showed generic "Missing required variable" instead of specific type conversion issues
- Fixed number type variables to properly handle both integers (`"123"`) and floats (`"123.45"`)
- Fixed date type variables to show clear error messages for invalid date formats
- Improved error messages to distinguish between truly missing variables and type conversion failures

#### Data Migration Required

If you have existing queries stored in your database with `static_options` in the old format, you will need to migrate them. See the [Migration Guide in README.md](README.md#upgrading-from-versions--090) for detailed instructions and migration script.

## [0.8.0] - 2025-09-03

### Added
- **NEW:** Two-level schema and table visibility system with schema rules taking precedence over table rules
- **NEW:** Comprehensive export system with CSV, JSON, and JSONL support for Lotus.Result structs
- Added `schema_visibility` configuration for controlling which schemas are accessible through Lotus
- Added schema visibility functions to `Lotus.Visibility` module:
  - `allowed_schema?/2` - Check if a schema is visible
  - `filter_schemas/2` - Filter a list of schemas by visibility rules
  - `validate_schemas/2` - Validate that all requested schemas are visible
- Added `builtin_schema_denies/1` callback to Source behaviour for adapter-specific system schema filtering
- Added automatic schema visibility filtering to `list_schemas` and `list_tables` functions
- Added implementation of `list_schemas` for all database adapters:
  - PostgreSQL: Returns actual schema names from `information_schema.schemata`
  - MySQL: Returns database names as schemas
  - SQLite: Returns empty list (no schema support)
- Added comprehensive MySQL adapter tests in `Lotus.SchemaTest` covering all schema introspection functions
- Added `Lotus.Export` module with `to_csv/1`, `to_json/1`, and `to_jsonl/1` functions for exporting query results
- Added protocol-based `Lotus.Export.Normalizer` system for database value normalization with support for:
  - All basic Elixir types (atoms, numbers, strings, booleans, dates/times)
  - Database-specific types (PostgreSQL ranges, intervals, INET, geometric types)
  - Binary data handling (UUIDs, Base64 encoding for non-UTF-8 data)
  - Collections (maps preserved for JSON, stringified for CSV)
  - Decimal types with proper NaN/Infinity handling
- Added battle-tested UUID binary handling using `Ecto.UUID.load/1`
- Added comprehensive test coverage for all export functionality and edge cases
- Added NimbleCSV integration for robust CSV generation with proper escaping
- Added central `Lotus.Value` module providing unified interface for value normalization across JSON/CSV/UI contexts

### Changed
- **BREAKING:** Renamed `Lotus.QueryResult` to `Lotus.Result` for cleaner API naming with the introduction of `Lotus.Value`

### Fixed
- Fixed SQL quoting in `get_table_stats` to use adapter-specific quote characters (backticks for MySQL, double quotes for PostgreSQL)
- Fixed MySQL builtin_denies to properly filter system tables with database-specific schema names
- Fixed PostgreSQL and MySQL schema tests to correctly expect errors (not empty results) for non-existent tables

## [0.7.0] - 2025-09-01

### Added
- **NEW:** Comprehensive caching system with adapter behaviour and ETS backend
- **NEW:** OTP application and supervisor support for production deployment
- Added `Lotus.Application` and `Lotus.Supervisor` for managed cache backend lifecycle
- Added `Lotus.child_spec/1` and `Lotus.start_link/1` for supervision tree integration
- Added `Lotus.Cache` behaviour for implementing custom cache adapters
- Added `Lotus.Cache.ETS` adapter providing in-memory caching with TTL support
- Added cache configuration with predefined profiles (`:results`, `:options`, `:schema`) that ship with built-in defaults and support custom TTL strategies
- Added cache namespace support for multi-tenant applications
- Added tag-based cache invalidation for targeted cache clearing
- Added cache modes: default caching, `:bypass` (skip cache), `:refresh` (update cache)
- Added cache key generation based on SQL, parameters, repository, search path, and Lotus version
- Added cache integration for both `run_sql/3` and `run_query/2` functions
- Added cache integration for all Schema functions (`list_tables/2`, `get_table_schema/3`, `get_table_stats/3`, `list_relations/2`)
- Added cache options passing (`max_bytes`, `compress`) through the API layer
- Added built-in cache profile defaults: `:results` (60s TTL), `:schema` (1h TTL), `:options` (5m TTL) - available without any configuration

### Enhanced
- Enhanced `run_sql/3` and `run_query/2` to automatically use configured cache when available
- Enhanced all Schema functions with read-through caching using appropriate profiles (`:schema` for metadata, `:results` for statistics)
- Enhanced cache system with automatic adapter detection and graceful fallback when no adapter configured
- Enhanced cache configuration with profile-specific TTL settings and runtime overrides
- **MAJOR:** Refactored schema introspection system to be completely database-agnostic with proper caching of table schema resolution queries

### Changed
- **BREAKING:** Renamed `Lotus.Adapter` behaviour to `Lotus.Source` in preparation for caching functionality and to support future non-SQL data sources
- **BREAKING:** Renamed adapter modules from `Lotus.Adapters.*` to `Lotus.Sources.*` (`Lotus.Sources.Postgres`, `Lotus.Sources.MySQL`, `Lotus.Sources.SQLite3`, `Lotus.Sources.Default`)
- **BREAKING:** Renamed `Lotus.SourceUtils` module to `Lotus.Sources` and expanded its functionality to include data source registration, dynamic module resolution, and comprehensive source management utilities
- **INTERNAL:** Moved all database-specific schema operations (`list_tables`, `get_table_schema`, `resolve_table_schema`) from `Lotus.Schema` to respective source modules for better separation of concerns
- **INTERNAL:** `Lotus.Schema` is now completely database-agnostic and delegates all DB-specific operations to source modules
- **PERFORMANCE:** Added caching to `resolve_table_schema` queries to eliminate the expensive "which schema is this table in?" database lookups that were being repeatedly executed

### Fixed
- Fixed schema introspection for SQLite databases by properly handling schema-less database architecture (empty schemas list instead of `["public"]`)

## [0.6.0] - 2025-08-31

### Added
- Added `Lotus.can_run?/1` and `Lotus.can_run?/2` functions to check if a query has all required variables available before execution
- Added `Lotus.SQL.Transformer` for transforming SQL queries to ensure database-specific syntax compatibility when using lotus variables
- Added `Lotus.SourceUtils` module providing utility functions for detecting data source types and feature support across adapters
- Added comprehensive interval query transformation support for PostgreSQL (INTERVAL syntax, make_interval functions)
- Added quoted wildcard pattern transformation for database-specific string concatenation (supports both PostgreSQL || and MySQL CONCAT)
- Added quoted variable placeholder stripping for cleaner parameter binding
- Added `reset_read_only/1` callback to adapter behaviour for resetting database sessions back to read-write mode after query execution

### Enhanced
- Enhanced query execution to automatically transform SQL statements based on target database adapter before parameter binding

### Fixed
- **CRITICAL:** Fixed database session persistence issue where session-level settings (`PRAGMA query_only` for SQLite, `SET SESSION TRANSACTION READ ONLY` and `max_execution_time` for MySQL) were not being properly restored after query execution, causing connection pool pollution that could break subsequent operations. Lotus now uses a robust snapshot/restore pattern to preserve and restore original session state for each database connection.

## [0.5.4] - 2025-08-29

### Fixed
- Fixed incomplete `@type opts()` specification - added missing `:repo` and `:vars` options to eliminate Dialyzer type errors

## [0.5.3] - 2025-08-29

### Enhanced
- Added type-specific SQL parameter placeholders for MySQL adapter supporting date, datetime, time, number, integer, boolean, and json types
- Added type-specific SQL parameter placeholders for PostgreSQL adapter supporting date, datetime, time, number, integer, boolean, and json types
- Added `extract_variables_from_statement/1` function to extract unique variable names from SQL statements in order of first occurrence
- Added `get_option_source/1` function to QueryVariable module to determine if options come from query or static sources

### Fixed
- Added proper type casting in parameter placeholders to ensure correct SQL data type handling across database adapters

## [0.5.2] - 2025-08-28

### Enhanced
- Enhanced `Lotus.run_query/2` variable resolution to properly merge default variable values with runtime overrides via `vars` option
- Improved `Lotus.run_query/2` documentation with comprehensive examples showing variable resolution order, type casting, and usage patterns

### Fixed
- Removed non-functional identifier variable substitution (e.g., `{{table}}` for table names) that would cause Ecto adapter crashes
- Clarified documentation that variables are only safe for SQL values (WHERE clauses, ORDER BY values), never for identifiers like table or column names

## [0.5.1] - 2025-08-27

### Fixed
- Fixed error handling for optional Ecto adapters - removed hardcoded references to specific adapter error structs (`Postgrex.Error`, `MyXQL.Error`, `Exqlite.Error`) to prevent compilation crashes when those adapters are not installed in host applications
- Added MySQL preflight authorization support with intelligent alias resolution and schema-qualified table parsing

### Changed
- Refactored adapter error formatting to use dynamic error type checking instead of pattern matching on specific error structs

## [0.5.0] - 2025-08-26

### Added
- Introduced `Lotus.Adapter` behaviour with dedicated implementations for PostgreSQL, SQLite, MySQL, and Default
- Added MySQL support with full adapter implementation using `:myxql` dependency
- Added `default_repo` configuration option for cleaner multi-database setup
- Added `param_placeholder/3` callback to adapter behaviour for generating database-specific SQL parameter placeholders
- Added `builtin_denies/1` callback to allow adapters to define system table filtering rules
- Added `handled_errors/0` callback to allow adapters to declare which exceptions they format
- Added MySQL development environment setup with Docker Compose

### Changed
- **BREAKING:** Removed `param_style/1` API in favor of `param_placeholder/4` facade that delegates to adapters
- **BREAKING:** Storage repo no longer used as fallback for query execution - only data repos are valid execution targets
- Enhanced configuration validation to require `default_repo` when multiple data repositories are configured
- Refactored error formatting to delegate based on `handled_errors/0`, ensuring cleaner and more extensible error handling
- Refactored table visibility system to use adapter-specific `builtin_denies/1` for system table filtering
- Consolidated adapter tests into a single facade-level `Lotus.AdapterTest` covering all supported databases

## [0.4.0] - 2025-08-26

### Added
- Database-level read-only protection for SQLite using `PRAGMA query_only` (SQLite 3.8.0+)
- Comprehensive CTE (Common Table Expression) destructive operation tests for both PostgreSQL and SQLite

### Changed
- **BREAKING:** Replaced `var_defaults` field with structured `variables` field for enhanced UI integration
- **BREAKING:** Changed variable placeholder syntax from `{var}` to `{{var}}` for better parsing
- **BREAKING:** Database schema migration removes `var_defaults` column and adds `variables` column to `lotus_queries` table
- Enhanced QueryVariable schema with type definitions (text, number, date), widget controls (input, select), labels, and option support
- Added `static_options` field for predefined dropdown choices
- Added `options_query` field for dynamic dropdown population from database queries
- Added validation to ensure select widgets define either `static_options` or `options_query`

## [0.3.3] - 2025-08-25

### Changed
- Improved table visibility rules: bare string patterns (e.g., `"api_keys"`) now match table names across all schemas in PostgreSQL, not just nil/empty schemas. This provides a more intuitive API where `"api_keys"` blocks the table in any schema, while `{"public", "api_keys"}` blocks it only in the public schema.

## [0.3.2] - 2025-08-25

- Change `statement` col from varchar to text

## [0.3.1] - 2025-08-25

- Specify `repo` option in `Lotus.run_sql`

## [0.3.0] - 2025-08-25

- **BREAKING:** Removed `tags` field from queries - queries no longer support tagging/filtering by tags
- **BREAKING:** Changed query field from `query` (map with `sql` and `params`) to `statement` (string)
- Add smart variable support with `{var}` placeholders in SQL statements
- Add `var_defaults` field to queries for providing default variable values
- Add comprehensive adapter tests for `Lotus.Adapter` module
- Add `get_query` to fetch queries without raising when they don't exist

## [0.2.0] - 2025-01-21

- **BREAKING:** Removed support for fk and pk configuration options
- **BREAKING:** Changed configuration structure - `repo` config replaced with `ecto_repo` and `data_repos`
- **BREAKING:** Removed unused `prefix` option from query execution opts (was never implemented)
- **BREAKING:** `list_tables` now returns `{schema, table}` tuples instead of just table names
- Add PostgreSQL per-query `search_path` support for multi-schema applications
- Add `search_path` field to stored queries for automatic schema resolution
- Add runtime `search_path` override option for ad-hoc queries
- Add `search_path` validation to prevent injection attacks
- Add preflight authorization support for `search_path` (EXPLAIN uses same path as execution)
- Add multi-schema support to `list_tables`, `get_table_schema`, and `get_table_stats`
- Add `list_relations` function to return tables with schema information
- Add schema-aware table discovery with `:schema`, `:schemas`, and `:search_path` options
- Add multi-database support with PostgreSQL and SQLite
- Add table visibility controls for enhanced security
- Add support for multiple data repositories with flexible routing
- Add `data_repo` field to stored queries for automatic repository selection
- Add comprehensive development environment setup with sample data
- Add read-only repository configuration guidance

## [0.1.0] - 2025-01-09
- Initial release
- Query storage, execution, and basic filtering
- Read-only SQL runner with safety checks
