# Telemetry

Lotus emits [`:telemetry`](https://hex.pm/packages/telemetry) events for query
execution, cache operations, and schema introspection. These events integrate
with monitoring tools like Phoenix LiveDashboard, AppSignal, Datadog, and others.

## Events

### Query Execution

| Event                         | Measurements                   | Metadata                                      |
|-------------------------------|--------------------------------|-----------------------------------------------|
| `[:lotus, :query, :start]`    | `system_time`                  | `source`, `statement`, `context`                         |
| `[:lotus, :query, :stop]`     | `duration`, `row_count`        | `source`, `statement`, `context`, `row_count`, `result`  |
| `[:lotus, :query, :exception]`| `duration`                     | `source`, `statement`, `context`, `kind`, `reason`, `stacktrace` |

Duration is measured in native time units. Use `System.convert_time_unit/3` to
convert to milliseconds or microseconds. On `:stop`, `row_count` appears in both
the measurements and the metadata — it is the same value.

The `source` field is the data source name (`"main"`, `"warehouse"`), not a
repo module. The `statement` field is a `%Lotus.Query.Statement{}`: read
`statement.body` for the adapter-native payload (SQL text for Ecto-backed
sources, a JSON object or AST for others) and `statement.params` for the bound
values. Pre-v1 `:repo`, `:sql` and `:params` metadata keys are gone.

The `context` field carries whatever value the caller passed as the `:context`
option to `Lotus.run_statement/3` or `Lotus.run_query/2`. It defaults to `nil` when
not provided. Typical uses include request IDs, controller names, or
OpenTelemetry span contexts for trace correlation. The `:scope` option is **not**
in the metadata — it is caller identity used for cache keys and visibility, not
instrumentation.

The events bracket statement execution — sanitization, preflight,
`:before_execute` and the query itself — so `:start` fires before any of those
run. Any failure among them — a denied table, a halted `:before_execute` plug, a
driver error — ends the run at `:exception`, not `:stop`.

Because Lotus turns those failures into `{:error, reason}` rather than letting
them raise, the `:exception` metadata is uniform: `kind` is always `:error`,
`reason` is the `{:error, reason}` tuple the caller receives, and `stacktrace`
is `[]`. Match on `reason` rather than expecting an exception struct.

Query telemetry brackets the phase the result cache stores, so a query served
from cache emits no `[:lotus, :query, *]` events at all; `[:lotus, :cache, :hit]`
is the event to count for those. The `:before_query` and `:after_query`
middleware run outside that phase, on every call: a plug that halts there yields
`{:error, reason}` to the caller without emitting query events, because no
statement ran.

### Cache Operations

| Event                      | Measurements | Metadata       |
|----------------------------|--------------|----------------|
| `[:lotus, :cache, :hit]`   | `count`      | `key`          |
| `[:lotus, :cache, :miss]`  | `count`      | `key`          |
| `[:lotus, :cache, :put]`   | `count`      | `key`, `ttl_ms`|

### Schema Introspection

| Event                                       | Measurements  | Metadata                    |
|---------------------------------------------|---------------|-----------------------------|
| `[:lotus, :schema, :introspection, :start]` | `system_time` | `operation`, `repo`         |
| `[:lotus, :schema, :introspection, :stop]`  | `duration`    | `operation`, `repo`, `result` |

The `operation` field is one of: `:list_schemas`, `:list_tables`,
`:describe_table`, `:get_table_stats`, or `:list_relations`.

The `result` field is `:ok` or `:error`.

> **Note:** these two events kept the metadata key `:repo`, unlike the query
> events which renamed it to `:source`. The value is the same thing in both —
> the data source *name* (`"main"`), not an Ecto repo module.

## Setup

Attach handlers in your application's `start/2` callback:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  :telemetry.attach_many(
    "lotus-telemetry",
    [
      [:lotus, :query, :stop],
      [:lotus, :query, :exception],
      [:lotus, :cache, :hit],
      [:lotus, :cache, :miss]
    ],
    &MyApp.LotusInstrumentation.handle_event/4,
    nil
  )

  children = [
    # ...
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Example Handler

```elixir
defmodule MyApp.LotusInstrumentation do
  require Logger

  def handle_event([:lotus, :query, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "Lotus query completed",
      duration_ms: duration_ms,
      row_count: measurements.row_count,
      source: metadata.source
    )
  end

  def handle_event([:lotus, :query, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "Lotus query failed",
      duration_ms: duration_ms,
      reason: inspect(metadata.reason),
      source: metadata.source,
      statement: inspect(metadata.statement.body)
    )
  end

  def handle_event([:lotus, :cache, :hit], _measurements, metadata, _config) do
    Logger.debug("Lotus cache hit", key: metadata.key)
  end

  def handle_event([:lotus, :cache, :miss], _measurements, metadata, _config) do
    Logger.debug("Lotus cache miss", key: metadata.key)
  end
end
```

## Phoenix LiveDashboard Integration

If you use [Phoenix LiveDashboard](https://hex.pm/packages/phoenix_live_dashboard),
you can add Lotus metrics to your telemetry supervisor:

```elixir
# lib/my_app_web/telemetry.ex
defp metrics do
  [
    # Lotus query metrics
    summary("lotus.query.stop.duration",
      unit: {:native, :millisecond},
      description: "Lotus query execution time"
    ),
    counter("lotus.query.stop.duration",
      description: "Total Lotus queries executed"
    ),
    counter("lotus.query.exception.duration",
      description: "Total Lotus query failures"
    ),

    # Cache metrics
    counter("lotus.cache.hit.count",
      description: "Lotus cache hits"
    ),
    counter("lotus.cache.miss.count",
      description: "Lotus cache misses"
    )
  ]
end
```

## Event Reference

For the complete list of events, measurements, and metadata fields, see
`Lotus.Telemetry`.
