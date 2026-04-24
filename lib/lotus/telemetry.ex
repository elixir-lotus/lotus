defmodule Lotus.Telemetry do
  @moduledoc """
  Telemetry events emitted by Lotus.

  Lotus uses `:telemetry` to emit events for query execution, cache operations,
  and schema introspection. You can attach handlers to these events for monitoring,
  logging, or integration with tools like Phoenix LiveDashboard or AppSignal.

  ## Query Events

  ### `[:lotus, :query, :start]`

  Emitted when a query begins execution.

  **Measurements:**

    * `:system_time` - The system time at the start of the query (in native units)

  **Metadata:**

    * `:repo` - The Ecto repo module
    * `:sql` - The SQL statement being executed
    * `:params` - The query parameters
    * `:context` - The caller-supplied context (or `nil`)

  ### `[:lotus, :query, :stop]`

  Emitted when a query completes successfully.

  **Measurements:**

    * `:duration` - The query duration (in native time units)
    * `:row_count` - The number of rows returned

  **Metadata:**

    * `:repo` - The Ecto repo module
    * `:sql` - The SQL statement that was executed
    * `:params` - The query parameters
    * `:context` - The caller-supplied context (or `nil`)
    * `:result` - The `Lotus.Result` struct

  ### `[:lotus, :query, :exception]`

  Emitted when a query fails with an exception.

  **Measurements:**

    * `:duration` - The time elapsed before the failure (in native time units)

  **Metadata:**

    * `:repo` - The Ecto repo module
    * `:sql` - The SQL statement that was executed
    * `:params` - The query parameters
    * `:context` - The caller-supplied context (or `nil`)
    * `:kind` - The kind of exception (`:error`, `:exit`, or `:throw`)
    * `:reason` - The exception or error reason
    * `:stacktrace` - The stacktrace

  ## Cache Events

  ### `[:lotus, :cache, :hit]`

  Emitted when a cache lookup finds an existing entry.

  **Measurements:**

    * `:count` - Always `1`

  **Metadata:**

    * `:key` - The cache key

  ### `[:lotus, :cache, :miss]`

  Emitted when a cache lookup does not find an entry.

  **Measurements:**

    * `:count` - Always `1`

  **Metadata:**

    * `:key` - The cache key

  ### `[:lotus, :cache, :put]`

  Emitted when a value is stored in the cache.

  **Measurements:**

    * `:count` - Always `1`

  **Metadata:**

    * `:key` - The cache key
    * `:ttl_ms` - The TTL in milliseconds

  ## Schema Introspection Events

  ### `[:lotus, :schema, :introspection, :start]`

  Emitted when a schema introspection operation begins.

  **Measurements:**

    * `:system_time` - The system time at the start (in native units)

  **Metadata:**

    * `:operation` - The introspection operation (e.g., `:list_schemas`, `:list_tables`,
      `:describe_table`, `:get_table_stats`, `:list_relations`)
    * `:repo` - The repo name

  ### `[:lotus, :schema, :introspection, :stop]`

  Emitted when a schema introspection operation completes.

  **Measurements:**

    * `:duration` - The operation duration (in native time units)

  **Metadata:**

    * `:operation` - The introspection operation
    * `:repo` - The repo name
    * `:result` - `:ok` or `:error`

  ## Example

  Attach a handler in your application's `start/2` callback:

      :telemetry.attach_many(
        "lotus-logger",
        [
          [:lotus, :query, :stop],
          [:lotus, :query, :exception],
          [:lotus, :cache, :hit],
          [:lotus, :cache, :miss]
        ],
        &MyApp.TelemetryHandler.handle_event/4,
        nil
      )

  A simple logging handler:

      defmodule MyApp.TelemetryHandler do
        require Logger

        def handle_event([:lotus, :query, :stop], measurements, metadata, _config) do
          duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
          Logger.info("Lotus query completed in \#{duration_ms}ms, rows: \#{measurements.row_count}")
        end

        def handle_event([:lotus, :query, :exception], measurements, metadata, _config) do
          duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
          Logger.error("Lotus query failed after \#{duration_ms}ms: \#{inspect(metadata.reason)}")
        end

        def handle_event([:lotus, :cache, :hit], _measurements, metadata, _config) do
          Logger.debug("Lotus cache hit: \#{metadata.key}")
        end

        def handle_event([:lotus, :cache, :miss], _measurements, metadata, _config) do
          Logger.debug("Lotus cache miss: \#{metadata.key}")
        end
      end
  """

  @query_start [:lotus, :query, :start]
  @query_stop [:lotus, :query, :stop]
  @query_exception [:lotus, :query, :exception]

  @cache_hit [:lotus, :cache, :hit]
  @cache_miss [:lotus, :cache, :miss]
  @cache_put [:lotus, :cache, :put]

  @schema_start [:lotus, :schema, :introspection, :start]
  @schema_stop [:lotus, :schema, :introspection, :stop]

  @doc false
  def events do
    [
      @query_start,
      @query_stop,
      @query_exception,
      @cache_hit,
      @cache_miss,
      @cache_put,
      @schema_start,
      @schema_stop
    ]
  end

  @doc false
  def query_start(metadata) do
    start_time = System.monotonic_time()
    :telemetry.execute(@query_start, %{system_time: System.system_time()}, metadata)
    start_time
  end

  @doc false
  def query_stop(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @query_stop,
      %{duration: duration, row_count: metadata[:row_count] || 0},
      metadata
    )
  end

  @doc false
  def query_exception(start_time, kind, reason, stacktrace, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @query_exception,
      %{duration: duration},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  @doc false
  def cache_hit(key) do
    :telemetry.execute(@cache_hit, %{count: 1}, %{key: key})
  end

  @doc false
  def cache_miss(key) do
    :telemetry.execute(@cache_miss, %{count: 1}, %{key: key})
  end

  @doc false
  def cache_put(key, ttl_ms) do
    :telemetry.execute(@cache_put, %{count: 1}, %{key: key, ttl_ms: ttl_ms})
  end

  @doc false
  def schema_introspection_start(operation, repo) do
    start_time = System.monotonic_time()

    :telemetry.execute(@schema_start, %{system_time: System.system_time()}, %{
      operation: operation,
      repo: repo
    })

    start_time
  end

  @doc false
  def schema_introspection_stop(start_time, operation, repo, result_status) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(@schema_stop, %{duration: duration}, %{
      operation: operation,
      repo: repo,
      result: result_status
    })
  end
end
