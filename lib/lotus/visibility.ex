defmodule Lotus.Visibility do
  @moduledoc """
  Schema, table and column visibility filtering for Lotus.

  Implements a three-level visibility system where the outer level takes
  precedence:

  1. **Schema visibility** is checked first — if a schema is denied, every
     table in it is blocked
  2. **Table visibility** is only checked if the schema is allowed
  3. **Column visibility** applies to the columns of an allowed table, and
     can hide a column from discovery or mask its values in results

  This ensures security by default while providing fine-grained control.

  ## Understanding Schemas Across Database Systems

  **Important**: "Schema" means different things in different databases:

  ### PostgreSQL
  - **True namespaced schemas** within a single database
  - Examples: `public`, `reporting`, `tenant_123`
  - System schemas: `pg_catalog`, `information_schema`, `pg_toast`

  ### MySQL
  - **Schemas = Databases** (synonymous terms)
  - Examples: `lotus_production`, `analytics_db`, `warehouse`
  - System schemas: `mysql`, `information_schema`, `performance_schema`, `sys`

  ### SQLite
  - **No schema support** (schema-less database)
  - Schema visibility rules don't apply

  ## Quick Start

  ```elixir
  config :lotus,
    # Schema-level rules (higher precedence)
    schema_visibility: %{
      postgres: [
        allow: ["public", ~r/^tenant_/],    # Only public + tenant schemas
        deny: ["legacy"]                    # Block legacy schema
      ],
      mysql: [
        allow: ["app_db", "analytics_db"],  # Only these databases
        deny: ["staging_db"]                # Block staging database
      ]
    },

    # Table-level rules (lower precedence)
    table_visibility: %{
      default: [
        deny: ["user_passwords", "api_keys", ~r/^audit_/]
      ],
      postgres: [
        allow: [
          {"public", ~r/^dim_/},           # Dimension tables only
          {"analytics", ~r/.*/}            # All analytics tables
        ]
      ]
    }
  ```

  ## Rule Evaluation

  ### 1. Schema Gating (First Check)
  ```elixir
  if not allowed_schema?(repo_name, schema) do
    false  # Schema denied → all tables blocked
  else
    # Schema allowed → check table rules
  end
  ```

  ### 2. Schema-Scoped Allow Posture
  Allow rules are **scoped to specific schemas**, not global:

  ```elixir
  # Rules: allow: [{"restricted", "allowed_table"}]

  {"restricted", "any_table"} → denied (has allow posture, must match)
  {"public", "any_table"} → allowed (no allow posture for public)
  ```

  ### 3. Deny Always Wins
  Any deny rule (builtin or user-defined) blocks access immediately.

  ## Rule Formats

  ### Schema Rules
  - `"exact_name"` - Matches exact schema name
  - `~r/pattern/` - Regex pattern for dynamic matching
  - `:all` - Special allow value (permits all schemas)

  ### Table Rules
  - `{"schema", "table"}` - Exact schema.table match
  - `{"schema", ~r/pattern/}` - Tables matching regex in specific schema
  - `{~r/schema_pattern/, "table"}` - Table in schemas matching pattern
  - `"table"` - Table name in any schema (global rule)

  ## Built-in Security

  System schemas are automatically denied:

  - **PostgreSQL**: `pg_catalog`, `information_schema`, `pg_toast`, `pg_temp_*`
  - **MySQL**: `mysql`, `information_schema`, `performance_schema`, `sys`
  - **All databases**: `schema_migrations`, `lotus_queries`

  ## Examples

  ### Multi-tenant Application
  ```elixir
  config :lotus,
    schema_visibility: %{
      postgres: [
        allow: ["public", ~r/^tenant_\\d+$/],  # tenant_123, etc.
        deny: ["admin"]
      ]
    },
    table_visibility: %{
      postgres: [
        allow: [
          {"public", ~r/^shared_/},        # Shared lookup tables
          {~r/^tenant_/, "users"},         # Users in each tenant
          {~r/^tenant_/, "orders"}         # Orders in each tenant
        ],
        deny: [
          {~r/^tenant_/, "audit_logs"}     # Hide audit logs
        ]
      ]
    }
  ```

  ### Data Warehouse
  ```elixir
  config :lotus,
    schema_visibility: %{
      postgres: [
        allow: ["public", "warehouse", "analytics"]
      ]
    },
    table_visibility: %{
      postgres: [
        allow: [
          {"public", ~r/^dim_/},         # Dimension tables
          {"public", ~r/^fact_/},        # Fact tables
          {"warehouse", ~r/.*/},         # All warehouse
          {"analytics", ~r/^report_/}    # Only reports
        ],
        deny: [
          {"public", ~r/^raw_/}          # Hide raw data
        ]
      ]
    }
  ```

  ### MySQL Multi-Database
  ```elixir
  config :lotus,
    schema_visibility: %{
      mysql: [
        # Remember: schemas = databases in MySQL
        allow: ["app_production", "analytics_warehouse"],
        deny: ["staging_db", "backup_db"]
      ]
    }
  ```

  ## API

  Direct visibility checking:
  ```elixir
  # Check schema visibility
  Lotus.Visibility.allowed_schema?("postgres", "public")  # true/false

  # Check table visibility
  Lotus.Visibility.allowed_relation?("postgres", {"public", "users"})  # true/false

  # Filter lists
  Lotus.Visibility.filter_schemas(["public", "pg_catalog"], "postgres")  # ["public"]

  # Validate requested schemas
  Lotus.Visibility.validate_schemas(["public", "restricted"], "postgres")
  # :ok | {:error, :schema_not_visible, denied: [...]}
  ```

  Schema-aware Lotus functions automatically apply visibility:
  ```elixir
  {:ok, schemas} = Lotus.list_schemas("postgres")        # Filtered list
  {:ok, tables} = Lotus.list_tables("postgres")          # Filtered list
  {:error, msg} = Lotus.list_tables("postgres", schemas: ["denied"])  # Error
  ```

  For more detailed examples and configuration patterns, see the
  [Visibility Guide](guides/visibility.html).
  """

  alias Lotus.Config
  alias Lotus.Source.Adapter
  alias Lotus.Visibility.Matcher

  @typedoc """
  What every check accepts in place of a source name: a compiled
  `Lotus.Visibility.Matcher`, or a raw rule set with optional `:schema`,
  `:table` and `:column` keys in the formats the resolver callbacks return.
  A raw rule set is compiled as given, with no builtin denies.
  """
  @type source :: String.t() | Matcher.t() | rules()

  @type rules :: %{
          optional(:schema) => keyword(),
          optional(:table) => keyword(),
          optional(:column) => list()
        }

  @doc """
  Compiles a rule set into a `Lotus.Visibility.Matcher`.

  Exact names become sets and regex rules a short ordered list, so a check
  against the matcher does not walk the raw rules. Pure: the same rules give
  the same matcher. A matcher passed in is returned as it is, apart from the
  merge below.

  ## Options

    * `:adapter` — an `%Lotus.Source.Adapter{}` whose built-in schema and
      table denies are merged into the matcher, or `nil` for the
      conservative fallback denies used when no source can be resolved.
    * `:builtin_schema_denies`, `:builtin_table_denies` — the deny lists to
      merge when the caller has them instead of the adapter.

  A resolver that serves rules changed at runtime compiles once when a rule
  set is written and returns the matcher from
  `c:Lotus.Visibility.Resolver.matcher_for/2`.
  """
  @spec compile(Matcher.t() | rules(), keyword()) :: Matcher.t()
  def compile(rules, opts \\ [])
  def compile(%Matcher{} = matcher, opts), do: merge_builtin(matcher, opts)
  def compile(%{} = rules, opts), do: rules |> Matcher.compile() |> merge_builtin(opts)

  defp merge_builtin(matcher, opts) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, %Adapter{} = adapter} ->
        Matcher.merge_builtin(
          matcher,
          Adapter.builtin_schema_denies(adapter),
          Adapter.builtin_denies(adapter)
        )

      {:ok, nil} ->
        Matcher.merge_builtin(matcher, Adapter.builtin_schema_denies(), Adapter.builtin_denies())

      :error ->
        Matcher.merge_builtin(
          matcher,
          Keyword.get(opts, :builtin_schema_denies, []),
          Keyword.get(opts, :builtin_table_denies, [])
        )
    end
  end

  @doc """
  Returns the compiled matcher for a source, from the configured resolver.

  A resolver that exports `c:Lotus.Visibility.Resolver.matcher_for/2`
  answers directly. Otherwise its three rule callbacks are compiled here,
  with the built-in denies of the source's adapter merged in.

  Call this once per result or per discovery call and pass the matcher to
  the checks below, instead of passing the source name to every check.
  """
  @spec matcher_for(String.t(), term()) :: Matcher.t()
  def matcher_for(source_name, scope \\ nil) when is_binary(source_name) do
    resolver = visibility_resolver()

    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :matcher_for, 2) do
      resolver.matcher_for(source_name, scope)
    else
      compile(
        %{
          schema: resolver.schema_rules_for(source_name, scope),
          table: resolver.table_rules_for(source_name, scope),
          column: resolver.column_rules_for(source_name, scope)
        },
        adapter: source_adapter(source_name)
      )
    end
  end

  @doc false
  @spec source_adapter(String.t()) :: Adapter.t() | nil
  def source_adapter(source_name) do
    case Config.source_resolver().resolve(source_name, nil) do
      {:ok, %Adapter{} = adapter} -> adapter
      _ -> nil
    end
  end

  @doc """
  Checks if a schema is visible for the given source.

  `source` is a source name, a compiled matcher or a raw rule set (see
  `t:source/0`).

  Returns:
  - `true` if the schema is allowed
  - `false` if the schema is denied
  """
  @spec allowed_schema?(source(), String.t() | nil, term()) :: boolean()
  def allowed_schema?(source, schema, scope \\ nil) do
    Matcher.allowed_schema?(matcher(source, scope), schema)
  end

  @doc """
  Checks if a relation (schema, table) is allowed for the given source.

  Schema visibility is checked first, then table visibility. `source` is a
  source name, a compiled matcher or a raw rule set (see `t:source/0`).
  """
  @spec allowed_relation?(source(), {String.t() | nil, String.t()}, term()) :: boolean()
  def allowed_relation?(source, {_schema, _table} = relation, scope \\ nil) do
    Matcher.allowed_relation?(matcher(source, scope), relation)
  end

  @doc """
  Filters a list of schemas to only those that are visible.
  """
  @spec filter_schemas([String.t()], source(), term()) :: [String.t()]
  def filter_schemas(schemas, source, scope \\ nil) do
    matcher = matcher(source, scope)
    Enum.filter(schemas, &Matcher.allowed_schema?(matcher, &1))
  end

  @doc """
  Filters a list of relations to only those that are visible.
  """
  @spec filter_relations([{String.t() | nil, String.t()}], source(), term()) ::
          [{String.t() | nil, String.t()}]
  def filter_relations(relations, source, scope \\ nil) do
    matcher = matcher(source, scope)
    Enum.filter(relations, &Matcher.allowed_relation?(matcher, &1))
  end

  @doc """
  Validates that all requested schemas are visible.

  Returns:
  - `:ok` if all schemas are visible
  - `{:error, :schema_not_visible, denied: [schemas]}` if any are denied
  """
  @spec validate_schemas([String.t()], source(), term()) ::
          :ok | {:error, :schema_not_visible, denied: [String.t()]}
  def validate_schemas(schemas, source, scope \\ nil) do
    matcher = matcher(source, scope)
    denied = Enum.reject(schemas, &Matcher.allowed_schema?(matcher, &1))

    if denied == [] do
      :ok
    else
      {:error, :schema_not_visible, denied: denied}
    end
  end

  @doc """
  Resolves the column policy for a given result column name in the context of
  accessed relations and source.

  `source` is a source name, a compiled matcher or a raw rule set (see
  `t:source/0`). Rules support patterns on schema, table, and column names.
  Returns a normalized policy map or nil.
  """
  @spec column_policy_for(source(), [{String.t() | nil, String.t()}] | nil, String.t(), term()) ::
          nil | %{action: atom(), mask: any(), show_in_schema?: boolean()}
  def column_policy_for(source, relations, result_column_name, scope \\ nil) do
    Matcher.column_policy(matcher(source, scope), relations, result_column_name)
  end

  defp matcher(%Matcher{} = matcher, _scope), do: matcher
  defp matcher(%{} = rules, _scope), do: compile(rules)

  defp matcher(source_name, scope) when is_binary(source_name),
    do: matcher_for(source_name, scope)

  defp visibility_resolver, do: Config.visibility_resolver()
end
