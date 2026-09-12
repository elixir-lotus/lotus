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
  alias Lotus.Visibility.Policy

  @doc """
  Checks if a schema is visible for the given data repo.

  Returns:
  - `true` if the schema is allowed
  - `false` if the schema is denied
  """
  @spec allowed_schema?(String.t(), String.t() | nil, term()) :: boolean()
  def allowed_schema?(repo_name, schema, scope \\ nil) do
    rules = visibility_resolver().schema_rules_for(repo_name, scope)
    builtin = builtin_schema_denies(repo_name)

    builtin_denied = schema_deny_hit?(builtin, schema)

    allowed = schema_allow_pass?(rules[:allow], schema)
    user_denied = schema_deny_hit?(rules[:deny], schema)

    # Schema is visible if:
    # - It passes allow rules (or no allow rules exist) AND
    # - It's not denied by builtin or user rules
    (allowed || rules[:allow] in [nil, [], :all]) and not (builtin_denied or user_denied)
  end

  @doc """
  Checks if a relation (schema, table) is allowed for the given data repo.

  This now checks schema visibility first, then table visibility.
  """
  @spec allowed_relation?(String.t(), {String.t() | nil, String.t()}, term()) :: boolean()
  def allowed_relation?(repo_name, {schema, table}, scope \\ nil) do
    if allowed_schema?(repo_name, schema, scope) do
      table_rules = visibility_resolver().table_rules_for(repo_name, scope)
      builtin = builtin_table_denies(repo_name)

      builtin_denied = deny_hit?(builtin, schema, table)
      allowed = allow_pass?(table_rules[:allow], schema, table)
      user_denied = deny_hit?(table_rules[:deny], schema, table)

      (allowed || table_rules[:allow] in [nil, []]) and not (builtin_denied or user_denied)
    else
      false
    end
  end

  @doc """
  Filters a list of schemas to only those that are visible.
  """
  @spec filter_schemas([String.t()], String.t(), term()) :: [String.t()]
  def filter_schemas(schemas, repo_name, scope \\ nil) do
    Enum.filter(schemas, &allowed_schema?(repo_name, &1, scope))
  end

  @doc """
  Filters a list of relations to only those that are visible.
  """
  @spec filter_relations([{String.t() | nil, String.t()}], String.t(), term()) ::
          [{String.t() | nil, String.t()}]
  def filter_relations(relations, repo_name, scope \\ nil) do
    Enum.filter(relations, &allowed_relation?(repo_name, &1, scope))
  end

  @doc """
  Validates that all requested schemas are visible.

  Returns:
  - `:ok` if all schemas are visible
  - `{:error, :schema_not_visible, denied: [schemas]}` if any are denied
  """
  @spec validate_schemas([String.t()], String.t(), term()) ::
          :ok | {:error, :schema_not_visible, denied: [String.t()]}
  def validate_schemas(schemas, repo_name, scope \\ nil) do
    denied = Enum.reject(schemas, &allowed_schema?(repo_name, &1, scope))

    if denied == [] do
      :ok
    else
      {:error, :schema_not_visible, denied: denied}
    end
  end

  defp builtin_schema_denies(repo_name) do
    case resolve_adapter(repo_name) do
      nil -> Adapter.builtin_schema_denies()
      adapter -> Adapter.builtin_schema_denies(adapter)
    end
  end

  defp schema_allow_pass?(nil, _schema), do: true
  defp schema_allow_pass?([], _schema), do: true
  defp schema_allow_pass?(:all, _schema), do: true

  defp schema_allow_pass?(rules, schema) do
    Enum.any?(rules, fn
      %Regex{} = rx -> schema_pattern_match?(rx, schema)
      str when is_binary(str) -> str == schema
      _ -> false
    end)
  end

  defp schema_deny_hit?(nil, _schema), do: false
  defp schema_deny_hit?([], _schema), do: false

  defp schema_deny_hit?(rules, schema) do
    Enum.any?(rules, fn
      %Regex{} = rx -> schema_pattern_match?(rx, schema)
      str when is_binary(str) -> str == schema
      _ -> false
    end)
  end

  defp schema_pattern_match?(%Regex{} = rx, val) when is_binary(val), do: Regex.match?(rx, val)
  defp schema_pattern_match?(%Regex{}, nil), do: false
  defp schema_pattern_match?(_, _), do: false

  # Table-level helpers (existing code)

  defp builtin_table_denies(repo_name) do
    case resolve_adapter(repo_name) do
      nil -> Adapter.builtin_denies()
      adapter -> Adapter.builtin_denies(adapter)
    end
  end

  defp resolve_adapter(repo_name) do
    case Config.source_resolver().resolve(repo_name, nil) do
      {:ok, %Adapter{} = adapter} -> adapter
      _ -> nil
    end
  end

  defp allow_pass?(nil, _s, _t), do: true
  defp allow_pass?([], _s, _t), do: true

  defp allow_pass?(rules, s, t) do
    schema_specific_rules =
      Enum.filter(rules, fn
        {rule_schema, _} when is_binary(rule_schema) or is_nil(rule_schema) ->
          pattern_match?(rule_schema, s)

        {%Regex{} = rule_schema, _} ->
          pattern_match?(rule_schema, s)

        _bare_string ->
          true
      end)

    if schema_specific_rules == [] do
      true
    else
      any_match?(schema_specific_rules, s, t)
    end
  end

  defp deny_hit?(nil, _s, _t), do: false
  defp deny_hit?([], _s, _t), do: false
  defp deny_hit?(rules, s, t), do: any_match?(rules, s, t)

  defp any_match?(rules, s, t) do
    Enum.any?(rules, fn
      {schema_pat, table_pat} ->
        pattern_match?(schema_pat, s) and pattern_match?(table_pat, t)

      tbl when is_binary(tbl) ->
        # Bare string matches table name regardless of schema
        # This makes "api_keys" match both {nil, "api_keys"} and {"public", "api_keys"}
        pattern_match?(tbl, t)

      # All 2-tuple and bare-string rules are handled above, so anything
      # reaching here is a malformed rule that can never match a relation.
      _other ->
        false
    end)
  end

  # IMPORTANT: only treat `nil` schema pattern as a match when the relation's schema is nil/""
  # (prevents SQLite-intended rules from matching Postgres relations)
  defp pattern_match?(%Regex{} = rx, val) when is_binary(val), do: Regex.match?(rx, val)
  defp pattern_match?(%Regex{}, nil), do: false
  defp pattern_match?(str, val) when is_binary(str) and is_binary(val), do: str == val
  defp pattern_match?(nil, s) when s in [nil, ""], do: true
  defp pattern_match?(nil, _), do: false
  defp pattern_match?(_, _), do: false

  @doc """
  Resolves the column policy for a given result column name in the context of
  accessed relations and repo.

  Rules are taken from `Lotus.Config.column_rules_for_source_name/1` and support patterns
  on schema, table, and column names. Returns a normalized policy map or nil.
  """
  @spec column_policy_for(String.t(), [{String.t() | nil, String.t()}], String.t(), term()) ::
          nil | %{action: atom(), mask: any(), show_in_schema?: boolean()}
  def column_policy_for(repo_name, relations, result_column_name, scope \\ nil) do
    rules = visibility_resolver().column_rules_for(repo_name, scope)
    rels = relations || []

    find_schema_table_column_match(rules, rels, result_column_name) ||
      find_table_column_match(rules, rels, result_column_name) ||
      find_column_only_match(rules, result_column_name)
  end

  defp find_schema_table_column_match(rules, rels, result_column_name) do
    Enum.find_value(rules, fn
      {schema_pat, table_pat, col_pat, policy} ->
        if rels != [] and
             schema_table_column_matches?(
               rels,
               schema_pat,
               table_pat,
               col_pat,
               result_column_name
             ) do
          normalize_policy(policy)
        end

      _ ->
        nil
    end)
  end

  defp find_table_column_match(rules, rels, result_column_name) do
    Enum.find_value(rules, fn
      {table_pat, col_pat, policy} ->
        if rels != [] and table_column_matches?(rels, table_pat, col_pat, result_column_name) do
          normalize_policy(policy)
        end

      _ ->
        nil
    end)
  end

  defp find_column_only_match(rules, result_column_name) do
    Enum.find_value(rules, fn
      {col_pat, policy} ->
        if cv_match?(col_pat, result_column_name), do: normalize_policy(policy)

      _ ->
        nil
    end)
  end

  defp schema_table_column_matches?(rels, schema_pat, table_pat, col_pat, result_column_name) do
    Enum.any?(rels, fn {s, t} ->
      cv_match?(schema_pat, s) and cv_match?(table_pat, t) and
        cv_match?(col_pat, result_column_name)
    end)
  end

  defp table_column_matches?(rels, table_pat, col_pat, result_column_name) do
    Enum.any?(rels, fn {_s, t} ->
      cv_match?(table_pat, t) and cv_match?(col_pat, result_column_name)
    end)
  end

  defp cv_match?(%Regex{} = rx, val) when is_binary(val), do: Regex.match?(rx, val)
  defp cv_match?(%Regex{}, _), do: false
  defp cv_match?("*", _), do: true
  defp cv_match?(str, val) when is_binary(str) and is_binary(val), do: str == val
  defp cv_match?(nil, s) when s in [nil, ""], do: true
  defp cv_match?(_, _), do: false

  defp normalize_policy(policy), do: Policy.normalize_column_policy(policy)

  defp visibility_resolver, do: Config.visibility_resolver()
end
