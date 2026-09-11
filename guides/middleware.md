# Middleware

Lotus provides a middleware pipeline that lets you hook into query execution and schema discovery events. Middleware follows the familiar Plug pattern — each module implements `init/1` and `call/2`.

## How It Works

A middleware module looks like this:

```elixir
defmodule MyApp.AuditMiddleware do
  def init(opts), do: opts

  def call(payload, _opts) do
    # Inspect or transform the payload
    {:cont, payload}   # continue to next middleware
    # or
    {:halt, "reason"}  # stop pipeline, Lotus returns {:error, reason}
  end
end
```

Each middleware receives a payload map whose contents depend on the pipeline event (see below), and must return either `{:cont, payload}` to continue or `{:halt, reason}` to abort.

## Pipeline Events

| Event | Triggered | Payload keys |
|-------|-----------|--------------|
| `:before_query` | Before sanitization, preflight and execution | `:statement`, `:source`, `:context` |
| `:after_query` | After execution, before result returned to caller | `:result`, `:statement`, `:source`, `:context` |
| `:after_list_schemas` | After schema discovery and visibility filtering | `:schemas`, `:source`, `:scope`, `:context` |
| `:after_list_tables` | After table discovery and visibility filtering | `:tables`, `:source`, `:scope`, `:context` |
| `:after_get_table_schema` | After table schema introspection and column visibility | `:columns`, `:table_name`, `:schema`, `:source`, `:scope`, `:context` |
| `:after_list_relations` | After relation discovery and visibility filtering | `:relations`, `:source`, `:scope`, `:context` |
| `:after_discover` | After any discovery call, following the kind-specific `:after_list_*` event | `:kind`, `:result`, `:source`, `:scope`, `:context` |

### Discovery event ordering

Discovery calls (`Lotus.list_schemas/2`, `list_tables/2`, `get_table_schema/3`, `list_relations/2`) fire **two** events per call:

1. The **kind-specific event** (`:after_list_schemas`, `:after_list_tables`, `:after_get_table_schema`, or `:after_list_relations`). The payload uses a key that matches the returned value (e.g. `:tables`, `:columns`). Register this event when you want the full kind-specific payload.
2. The **unified `:after_discover` event**. The payload is always `%{kind:, source:, result:, scope:, context:}`. Register this event when you want a single middleware module that handles every discovery kind by dispatching on `:kind`.

If any middleware in either phase halts, later middleware do not run and the caller receives `{:error, reason}`. The kind-specific event always runs before `:after_discover`; halting in the kind-specific phase short-circuits `:after_discover`.

The `:kind` value in the unified event is one of `:list_schemas`, `:list_tables`, `:get_table_schema`, or `:list_relations`. Pattern-match on it and mutate `:result` in-place:

```elixir
defmodule MyApp.DiscoveryAuditMiddleware do
  require Logger

  def init(opts), do: opts

  def call(%{kind: kind, source: source, result: result, scope: _scope, context: ctx} = payload, _opts) do
    user = Map.get(ctx || %{}, :user_id, "anonymous")
    Logger.info("[Lotus] discover kind=#{kind} source=#{source} user=#{user} count=#{length(result)}")
    {:cont, payload}
  end
end
```

## Rewriting the Statement

A `:before_query` plug may replace the `:statement` in its payload, and the
statement it returns is the one Lotus executes:

```elixir
defmodule MyApp.TenantScope do
  def init(opts), do: opts

  def call(%{statement: statement, context: %{tenant_id: id}} = payload, _opts) do
    scoped = %{statement | body: "SELECT * FROM (#{statement.body}) t WHERE tenant_id = $#{length(statement.params) + 1}",
               params: statement.params ++ [id]}

    {:cont, %{payload | statement: scoped}}
  end

  def call(payload, _opts), do: {:cont, payload}
end
```

Because the rewritten statement is what runs, `:before_query` fires **before**
statement sanitization and preflight authorization — both apply to the final
statement, not the text the caller supplied. A plug cannot rewrite its way
onto a denied table, and cannot turn a read into a write when `read_only` is
in force.

Returning the payload unchanged leaves the original statement in place, so
existing audit and access-control plugs need no changes.

## Configuration

Register middleware in your Lotus config. Each entry is a `{module, opts}` tuple — `opts` is passed to `init/1` at compile time:

```elixir
config :lotus,
  middleware: %{
    before_query: [
      {MyApp.AccessControlMiddleware, []},
      {MyApp.QueryAuditMiddleware, [repo: MyApp.AuditRepo]}
    ],
    after_query: [
      {MyApp.ResultRedactionMiddleware, [fields: ~w(email phone ssn)]}
    ],
    after_list_tables: [
      {MyApp.TableFilterMiddleware, []}
    ]
  }
```

Middleware runs in the order listed. Multiple middleware can be chained on the same event.

## Context

A `:context` key carries opaque user data (e.g. the current user) through to middleware. Lotus never inspects this value — it's purely for your application's use.

```elixir
# Pass context when running a query
Lotus.run_statement("SELECT * FROM orders", [], context: %{user_id: current_user.id})
```

```elixir
defmodule MyApp.AccessControlMiddleware do
  def init(opts), do: opts

  def call(%{context: %{user_id: nil}} = _payload, _opts) do
    {:halt, "authentication required"}
  end

  def call(payload, _opts) do
    {:cont, payload}
  end
end
```

## Examples

### Audit Logging

Log every query execution with the user who ran it:

```elixir
defmodule MyApp.QueryAuditMiddleware do
  require Logger

  def init(opts), do: opts

  def call(%{sql: sql, context: context} = payload, _opts) do
    user_id = Map.get(context || %{}, :user_id, "anonymous")
    Logger.info("[Lotus] user=#{user_id} sql=#{inspect(sql)}")
    {:cont, payload}
  end
end
```

### Row-Level Security

Block queries that don't include a tenant filter:

```elixir
defmodule MyApp.TenantMiddleware do
  def init(opts), do: opts

  def call(%{sql: sql, context: context} = payload, _opts) do
    tenant_id = Map.get(context || %{}, :tenant_id)

    cond do
      is_nil(tenant_id) ->
        {:halt, "tenant context required"}

      not String.contains?(String.downcase(sql), "tenant_id") ->
        {:halt, "queries must filter by tenant_id"}

      true ->
        {:cont, payload}
    end
  end
end
```

> **Note:** The `String.contains?` check above is intentionally simplified for illustration. It can be bypassed (e.g. via SQL comments). For real row-level security, inject a parameterized filter using the `:filters` option on `Lotus.run_query/2` instead of inspecting raw SQL text.

### Redacting Sensitive Data in Results

Mask PII columns (emails, phone numbers, etc.) so non-admin users only see partial values:

```elixir
defmodule MyApp.ResultRedactionMiddleware do
  @moduledoc """
  Masks sensitive columns in query results based on configurable field names.
  Admins (identified via context) see full values; everyone else sees masked output.
  """

  def init(opts), do: Keyword.get(opts, :fields, [])

  def call(%{result: result, context: context} = payload, fields) do
    if admin?(context) do
      {:cont, payload}
    else
      col_indexes =
        result.columns
        |> Enum.with_index()
        |> Enum.filter(fn {col, _i} -> col in fields end)
        |> Enum.map(fn {_col, i} -> i end)
        |> MapSet.new()

      redacted_rows =
        Enum.map(result.rows, fn row ->
          row
          |> Enum.with_index()
          |> Enum.map(fn {val, i} ->
            if i in col_indexes, do: mask(val), else: val
          end)
        end)

      {:cont, put_in(payload, [:result, Access.key(:rows)], redacted_rows)}
    end
  end

  defp admin?(%{role: :admin}), do: true
  defp admin?(_), do: false

  defp mask(val) when is_binary(val) and String.length(val) > 4 do
    String.slice(val, 0, 2) <> String.duplicate("*", max(String.length(val) - 4, 3)) <> String.slice(val, -2, 2)
  end

  defp mask(_val), do: "****"
end
```

Configure which fields to redact:

```elixir
config :lotus,
  middleware: %{
    after_query: [
      {MyApp.ResultRedactionMiddleware, [fields: ~w(email phone ssn)]}
    ]
  }
```

A query like `SELECT name, email FROM users` would return:

| name | email |
|------|-------|
| Alice Johnson | al***************om |
| Bob Smith | bo***********om |

### Filtering Schema Discovery

Hide internal tables from the schema browser:

```elixir
defmodule MyApp.TableFilterMiddleware do
  @hidden_prefixes ["_internal_", "oban_"]

  def init(opts), do: opts

  def call(%{tables: tables} = payload, _opts) do
    filtered = Enum.reject(tables, fn table ->
      Enum.any?(@hidden_prefixes, &String.starts_with?(table.name, &1))
    end)

    {:cont, %{payload | tables: filtered}}
  end
end
```

## Caching and Context

Discovery middleware (`:after_list_*`, `:after_discover`) runs **outside** the schema cache callback. The adapter result with visibility filtering applied is cached; middleware re-runs on every call against that cached result.

- **Context-sensitive middleware is safe.** Two callers with different `:context` values receive results filtered by their own middleware logic, not each other's cached output.
- **Middleware runs on every call**, not only on cache misses. Side-effecting middleware (e.g. audit logging) should budget accordingly.
- **Adapter calls are still cached.** The schema cache short-circuits the underlying `Adapter.list_tables/3` (etc.) on repeat calls — only the middleware pipeline re-runs.

## Halting the Pipeline

When a middleware returns `{:halt, reason}`, the pipeline stops immediately and Lotus returns `{:error, reason}` to the caller. This is useful for enforcing access control, rate limiting, or any validation that should prevent execution:

```elixir
def call(%{sql: sql} = payload, _opts) do
  if String.contains?(String.downcase(sql), "pg_sleep") do
    {:halt, "pg_sleep is not allowed"}
  else
    {:cont, payload}
  end
end
```
