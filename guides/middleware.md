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
| `:before_query` | Before sanitization, preflight and execution | `:statement`, `:source`, `:context`, `:vars` |
| `:before_execute` | After sanitization and preflight pass, before execution — or, on a cache hit, before the stored result is returned | `:statement`, `:relations`, `:origin`, `:source`, `:context`, `:vars` |
| `:after_query` | After execution, before result returned to caller | `:result`, `:statement`, `:relations`, `:origin`, `:source`, `:context`, `:vars` |
| `:after_list_schemas` | After schema discovery and visibility filtering | `:schemas`, `:source`, `:scope`, `:context` |
| `:after_list_tables` | After table discovery and visibility filtering | `:tables`, `:source`, `:scope`, `:context` |
| `:after_describe_table` | After table schema introspection and column visibility | `:columns`, `:table_name`, `:schema`, `:source`, `:scope`, `:context` |
| `:after_list_relations` | After relation discovery and visibility filtering | `:relations`, `:source`, `:scope`, `:context` |
| `:after_discover` | After any discovery call, following the kind-specific `:after_list_*` event | `:kind`, `:result`, `:source`, `:scope`, `:context` |

`:vars` is the map of bound query variables by name, after defaults and caller-supplied values are merged. It is `%{}` for a raw statement run through `Lotus.run_statement/3`.

### The contract

What a plug can rely on, release to release:

- **Phase order is fixed.** `:before_query`, then sanitization, preflight and `:before_execute`, then execution, then `:after_query`. The order lives in one place, `Lotus.Runner.run/4`, whether or not the result cache is involved.
- **Every query event fires on a cache hit.** See [Caching](#caching). `:before_execute` gets the relations stored with the entry; `:after_query` gets the stored result.
- **Payload keys are additive.** A release may add a key to a payload; it does not remove or rename one. Match on the keys you use, not on the whole map.
- **`:relations` follows one rule.** A list is proven, an empty list means "touches nothing", a tuple means "unknown". `:before_execute` and `:after_query` carry the same value.
- **Halting is final.** A halt returns `{:error, reason}` to the caller and later events for that run do not fire.
- **Observation is telemetry's job.** A plug sees only its own event. To record every run, including refusals and cache-served reads, attach to `[:lotus, :run, :start | :stop | :exception]` — see `Lotus.Telemetry`.

### The exact-count run

`window: [count: :exact]` runs a second statement, derived from the page statement, to compute `meta.total_count`. That run carries the caller's `:context`, `:vars`, `:scope` and read-only setting. It fires `:before_execute` (it touches the same tables as the page and is authorised the same way) but not `:before_query` (it is derived from the statement that hook already returned, so a rewriting plug would apply twice) and not `:after_query` (it has no result the caller reads). A halt on the count run leaves `meta.total_count` as `nil` and the page result intact.

### Discovery event ordering

Discovery calls (`Lotus.list_schemas/2`, `Lotus.list_tables/2`, `Lotus.describe_table/3`, `Lotus.list_relations/2`) fire **two** events per call:

1. The **kind-specific event** (`:after_list_schemas`, `:after_list_tables`, `:after_describe_table`, or `:after_list_relations`). The payload uses a key that matches the returned value (e.g. `:tables`, `:columns`). Register this event when you want the full kind-specific payload.
2. The **unified `:after_discover` event**. The payload is always `%{kind:, source:, result:, scope:, context:}`. Register this event when you want a single middleware module that handles every discovery kind by dispatching on `:kind`.

If any middleware in either phase halts, later middleware do not run and the caller receives `{:error, reason}`. The kind-specific event always runs before `:after_discover`; halting in the kind-specific phase short-circuits `:after_discover`.

The `:kind` value in the unified event is one of `:list_schemas`, `:list_tables`, `:describe_table`, or `:list_relations`. Pattern-match on it and mutate `:result` in-place:

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

## Authorizing on the Tables a Statement Touches

`:before_query` runs before the statement is analysed, so at that point Lotus
does not yet know which tables it reads. `:before_execute` runs after
sanitization and preflight have passed and before the statement executes, and
its payload carries `:relations` — the `{schema, table}` pairs preflight proved
the statement touches, for the statement a `:before_query` plug rewrote:

```elixir
defmodule MyApp.TableAuthz do
  def init(opts), do: opts

  def call(%{relations: relations, context: %{user: user}} = payload, _opts)
      when is_list(relations) do
    if Enum.all?(relations, &MyApp.Authz.may_read?(user, &1)) do
      {:cont, payload}
    else
      {:halt, "not authorized for one of the tables this query reads"}
    end
  end

  # A tuple — `{:unrestricted, reason}` or `{:skipped, reason}` — means Lotus
  # could not name the tables. A plug that gates on the list refuses rather
  # than read it as an empty set.
  def call(_payload, _opts), do: {:halt, "cannot determine which tables this query reads"}
end
```

Halting returns `{:error, reason}` to the caller and the statement never runs.

`:relations` is a list when preflight proved the set, and an empty list means
the statement touches no relation (`SELECT 1` passes the plug above with
`Enum.all?` over nothing). It is `{:unrestricted, reason}` when the adapter
cannot name the relations a statement touches (Elasticsearch, for one) and the
host opted in via `:allow_unrestricted_resources`, and `{:skipped, reason}`
when the adapter does not preflight the statement at all — the SQL adapters
skip `EXPLAIN`, `SHOW` and `PRAGMA`. The two tuples are distinct so a plug can
log which case it hit, and both mean "unknown".

`:after_query` carries the same `:relations`, so a plug that shapes a result
by table — drop or mask columns of one relation, annotate another — does so
without a second analysis. Both events also carry `:origin`, `:executed` or
`:cached`.

The two query hooks answer different questions, and both can be registered:

| Hook | Question |
|------|----------|
| `:before_query` | May this caller run a statement, and what statement should run? |
| `:before_execute` | Given what this statement provably touches, may it proceed? |

A row-level-security plug that rewrites the statement uses the first. An
authorization plug that gates on tables uses the second. A `:before_execute`
plug may not rewrite the statement: preflight has already authorized the one in
the payload, and that is the one that executes.

## Configuration

Register middleware in your Lotus config. Each entry is a `{module, opts}` tuple — `opts` is passed to `init/1` at compile time:

```elixir
config :lotus,
  middleware: %{
    before_query: [
      {MyApp.AccessControlMiddleware, []},
      {MyApp.QueryAuditMiddleware, [repo: MyApp.AuditRepo]}
    ],
    before_execute: [
      {MyApp.TableAuthz, []}
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

The config is compiled once — `init/1` runs at compile time and the result is
stored in `:persistent_term`. Reloading the config recompiles the pipeline, and
**an empty (or absent) `:middleware` config clears it**: a reload that no longer
declares middleware actually turns it off rather than leaving the previous
pipeline in place.

## Context and Scope

Two separate options reach middleware, and they are not interchangeable.

`:context` is opaque caller data (e.g. the current user, a request id). Lotus
never inspects it and it never affects execution. It is present on every event
payload.

`:scope` identifies *who is asking*. Lotus hashes it into cache keys and passes
it to the visibility resolver, so a resolver can hide tables or mask columns per
tenant or per role. It is present on the discovery event payloads
(`:after_list_*`, `:after_discover`), not on the query events.

```elixir
# Pass both when running a query
Lotus.run_statement("SELECT * FROM orders", [],
  context: %{user_id: current_user.id},
  scope: %{tenant_id: current_user.tenant_id}
)
```

> **The result cache key includes `:scope` but never `:context`.** Middleware
> runs outside the cache callback, so a plug that masks or filters results per
> actor works from `:context` alone — it sees every call, hit or miss. The
> visibility resolver does not: it runs inside the callback, so a resolver that
> hides tables or masks columns per actor needs the caller to pass a `:scope`
> identifying that actor, or one actor's stored result is served to the next.
> See [Caching](#caching). `Lotus.invalidate_scope/1` clears both the discovery
> and result cache entries for a given scope.

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

Log each query execution with the user who ran it. `:before_query` runs outside
the result cache, so this records every call, cached or not — see
[Caching](#caching) below.

```elixir
defmodule MyApp.QueryAuditMiddleware do
  require Logger

  def init(opts), do: opts

  def call(%{statement: statement, source: source, context: context} = payload, _opts) do
    user_id = Map.get(context || %{}, :user_id, "anonymous")
    Logger.info("[Lotus] user=#{user_id} source=#{source} body=#{inspect(statement.body)}")
    {:cont, payload}
  end
end
```

`statement.body` is adapter-opaque: SQL text for an Ecto-backed source, a JSON
map or DSL term for others. Use `inspect/1` rather than string interpolation so
the plug works for every source type.

### Row-Level Security

Block queries that don't include a tenant filter:

```elixir
defmodule MyApp.TenantMiddleware do
  def init(opts), do: opts

  def call(%{statement: statement, context: context} = payload, _opts) do
    tenant_id = Map.get(context || %{}, :tenant_id)

    cond do
      is_nil(tenant_id) ->
        {:halt, "tenant context required"}

      not String.contains?(String.downcase(statement.body), "tenant_id") ->
        {:halt, "queries must filter by tenant_id"}

      true ->
        {:cont, payload}
    end
  end
end
```

> **Note:** The `String.contains?` check above is intentionally simplified for illustration. It can be bypassed (e.g. via SQL comments). For real row-level security, inject a parameterized filter using the `:filters` option on `Lotus.run_query/2` instead of inspecting raw SQL text.

### Limiting Variable Values

Reject a query when the caller picks a date range that is too wide. The plug reads the bound variables from `:vars`, so it works on every path that runs a saved query: the editor, dashboards, exports and the AI assistant.

```elixir
config :lotus,
  middleware: %{before_query: [{MyApp.DateRangeLimit, max_days: 5}]}

defmodule MyApp.DateRangeLimit do
  def init(opts), do: opts

  def call(%{vars: %{"start_date" => from, "end_date" => to}} = payload, opts) do
    with {:ok, from} <- Date.from_iso8601(to_string(from)),
         {:ok, to} <- Date.from_iso8601(to_string(to)),
         true <- Date.diff(to, from) <= opts[:max_days] do
      {:cont, payload}
    else
      _ -> {:halt, "Date range must be #{opts[:max_days]} days or less"}
    end
  end

  # Queries without those variables are not affected.
  def call(payload, _opts), do: {:cont, payload}
end
```

Use `payload.context` in the same plug for per-user exceptions, or `payload.source` for per-source limits.

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

## Caching

Query middleware and discovery middleware both sit outside their caches. Only
the raw work an adapter does is stored.

### Every query event fires on a cache hit

`:before_query`, `:before_execute` and `:after_query` all run on a call served
from the cache:

- **Side-effecting plugs see every call.** An audit plug records hits and misses
  alike, and a plug that halts for one caller halts whether or not the cache is
  warm.
- **Context-sensitive plugs are safe.** `:context` is not part of the cache key,
  and for middleware it does not need to be: two callers with different
  `:context` values each get their own middleware decision on the same stored
  rows.
- **`:before_execute` gets its relations either way.** The relations preflight
  named are stored with the result, so the event carries them on a hit as well
  as on a miss — a plug that authorizes a statement against its tables is an
  access control, and one a warm cache skips would be no control at all. The
  payload says which case it is: `origin: :cached` on a hit, `:executed` on a
  miss.
- **The stored entry keeps the raw result.** `:after_query` runs on the way out,
  so what a plug makes of the result is returned to that caller and never
  written back. A halt there withholds the result from that caller; the rows
  themselves stay in the cache for a caller whose own plugs let them through.

A `:before_query` plug that rewrites the statement keys its own cache entry.
`:before_query` runs before pagination, so the plug is handed the query the
caller wrote rather than a `LIMIT` wrapper around it, and everything that keys
the entry — the body, the bound values, the window — describes the statement the
plug returned. A plug that filters through a bound parameter rather than through
the statement text is keyed just the same.

Pass `cache: :bypass` on a call that must never be served from the cache, or
`cache: :refresh` to re-run and re-seed it.

### What a cache hit does skip

Everything between sanitization and the returned rows is what the entry stores,
so a hit skips it: the adapter's statement sanitization, preflight table
authorization, and column visibility — `mask`, `omit`, and the hidden-column
error. Those controls read `:scope`, and `:scope` is part of the cache key, so
two scopes never share an entry.

**`:scope` is the only caller identity the result cache separates on.** A
visibility resolver must therefore decide from `(source, relations, column,
scope)` alone. A resolver that varies its rules by anything else — a user read
out of `:context`, process state, or the current request — masks the warming
caller's result and then serves it unchanged to the next caller. Carry the actor
in `:scope` when visibility depends on it, and keep per-actor logic that cannot
be expressed that way in middleware, which runs on every call.

### Discovery middleware runs outside the schema cache

Discovery middleware (`:after_list_*`, `:after_discover`) runs **outside** the schema cache callback. The adapter result with visibility filtering applied is cached; middleware re-runs on every call against that cached result.

- **Context-sensitive middleware is safe.** Two callers with different `:context` values receive results filtered by their own middleware logic, not each other's cached output.
- **Middleware runs on every call**, not only on cache misses. Side-effecting middleware (e.g. audit logging) should budget accordingly.
- **Adapter calls are still cached.** The schema cache short-circuits the underlying `Adapter.list_tables/3` (etc.) on repeat calls — only the middleware pipeline re-runs.

## Halting the Pipeline

When a middleware returns `{:halt, reason}`, the pipeline stops immediately and Lotus returns `{:error, reason}` to the caller. This is useful for enforcing access control, rate limiting, or any validation that should prevent execution:

```elixir
def call(%{statement: %{body: body}} = payload, _opts) when is_binary(body) do
  if String.contains?(String.downcase(body), "pg_sleep") do
    {:halt, "pg_sleep is not allowed"}
  else
    {:cont, payload}
  end
end

def call(payload, _opts), do: {:cont, payload}
```
