defmodule Lotus.Telemetry do
  @moduledoc """
  Telemetry events emitted by Lotus.

  Lotus uses `:telemetry` to emit events for query execution, cache operations,
  and schema introspection. You can attach handlers to these events for monitoring,
  logging, or integration with tools like Phoenix LiveDashboard or AppSignal.

  ## Run Events

  A run is one call to `Lotus.run_query/2`, `Lotus.run_statement/3` or
  `Lotus.Runner.run_statement/3`: `:before_query`, the execute step (or the
  result cache), `:before_execute`, `:after_query`. The run events bracket all
  of it, on every path — a result served from the cache, a statement a plug
  halted in any phase — and always carry the caller's `:context`. A consumer
  that records who ran what, whether it was served from the cache and whether
  it was refused attaches to these three events.

  The query events below cover only the execute step: a result served from
  the cache emits no query event, and neither does a run a plug halted before
  execution.

  ### `[:lotus, :run, :start]`

  **Measurements:** `:system_time`.

  **Metadata:**

    * `:source` - The data source name
    * `:statement` - The `Lotus.Query.Statement` the caller supplied, before
      any `:before_query` rewrite
    * `:context` - The caller-supplied context (or `nil`)
    * `:vars` - The bound query variables, by name

  ### `[:lotus, :run, :stop]`

  Emitted when a run completes and its result is returned to the caller.

  **Measurements:** `:duration` (native units), `:row_count`.

  **Metadata:** the start metadata, with `:statement` now the statement that
  ran, plus:

    * `:result` - The `Lotus.Result` returned to the caller
    * `:relations` - What preflight knew about the statement: a list of
      `{schema, table}`, `{:unrestricted, reason}` or `{:skipped, reason}`
    * `:origin` - `:executed` or `:cached`

  ### `[:lotus, :run, :exception]`

  Emitted when any phase of a run fails, including a middleware halt.

  **Measurements:** `:duration`.

  **Metadata:** the start metadata plus:

    * `:phase` - `:before_query`, `:sanitize`, `:preflight`,
      `:before_execute`, `:execute` or `:after_query`
    * `:reason` - The error or halt reason the caller receives
    * `:kind` - `:error`
    * `:statement`, `:relations`, `:origin` - Present when the failure came
      after the execute step, describing what ran

  ## Query Events

  ### `[:lotus, :query, :start]`

  Emitted when a query begins execution.

  **Measurements:**

    * `:system_time` - The system time at the start of the query (in native units)

  **Metadata:**

    * `:source` - The data source name (e.g. `"main"`, `"warehouse"`)
    * `:statement` - The `Lotus.Query.Statement` being executed. Its `:body`
      is the adapter-native payload and `:params` the bound values.
    * `:context` - The caller-supplied context (or `nil`)

  ### `[:lotus, :query, :stop]`

  Emitted when a query completes successfully.

  **Measurements:**

    * `:duration` - The query duration (in native time units)
    * `:row_count` - The number of rows returned

  **Metadata:**

    * `:source` - The data source name
    * `:statement` - The `Lotus.Query.Statement` that was executed
    * `:context` - The caller-supplied context (or `nil`)
    * `:result` - The `Lotus.Result` struct

  ### `[:lotus, :query, :exception]`

  Emitted when a query fails with an exception.

  **Measurements:**

    * `:duration` - The time elapsed before the failure (in native time units)

  **Metadata:**

    * `:source` - The data source name
    * `:statement` - The `Lotus.Query.Statement` that was executed
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
    * `:source` - The data source name

  ### `[:lotus, :schema, :introspection, :stop]`

  Emitted when a schema introspection operation completes.

  **Measurements:**

    * `:duration` - The operation duration (in native time units)

  **Metadata:**

    * `:operation` - The introspection operation
    * `:source` - The data source name
    * `:result` - `:ok` or `:error`

  ## Content Events

  A content change is one create, update or delete of a query, visualization,
  dashboard, dashboard card, dashboard filter or filter mapping, including
  enabling or disabling public sharing and moving a card in a reorder. The
  content events bracket each change on every path — a refusal, a failed
  validation, an update that writes nothing — and always carry the caller's
  `:context`. A reorder emits one span per card it moves.

  ### `[:lotus, :content, :change, :start]`

  **Measurements:** `:system_time`.

  **Metadata:**

    * `:op` - `:create`, `:update`, `:delete`, `:enable_sharing` or
      `:disable_sharing`
    * `:resource` - `:query`, `:visualization`, `:dashboard`,
      `:dashboard_card`, `:dashboard_filter` or `:filter_mapping`
    * `:record` - The struct as stored, or `nil` on a create
    * `:context` - The caller-supplied context (or `nil`)

  ### `[:lotus, :content, :change, :stop]`

  Emitted when the change completes. The metadata is the
  `:after_content_change` middleware payload. It is also emitted for an update
  that wrote nothing, which fires no `:after_content_change`.

  **Measurements:** `:duration` (native units).

  **Metadata:** the start metadata, with `:record` now the struct as written,
  plus:

    * `:changes` - Each changed field with its written value; `%{}` on a
      delete and on an update that wrote nothing

  ### `[:lotus, :content, :change, :exception]`

  Emitted when the change fails: a `:before_content_change` plug refused it, the
  changeset was invalid, or the write raised, threw or exited. In a reorder,
  every card change of the call shares the outcome.

  **Measurements:** `:duration`.

  **Metadata:** the start metadata plus:

    * `:kind` - `:error`, or `:throw` or `:exit` when the call did not return
    * `:reason` - The error the caller receives: `{:halted, reason}` for a
      refusal, the `Ecto.Changeset` for a failed validation
    * `:stacktrace` - Present when the call raised, threw or exited

  ## AI Events

  An AI request is one call of `Lotus.AI.generate_query/1`,
  `generate_query_with_context/1`, `suggest_optimizations/1` or
  `explain_query/1` that reaches the model: every round of its tool loop
  (the model asks for a table's columns, Lotus answers, the model goes on)
  belongs to the one request. A request a `:before_ai_request` plug refuses
  never reaches the model and emits no AI event. The statements and
  introspection the model asks for emit their own run and schema events,
  with the same `:context`.

  ### `[:lotus, :ai, :request, :start]`

  **Measurements:** `:system_time`.

  **Metadata:**

    * `:feature` - `:generation`, `:optimization` or `:explanation`
    * `:model` - The model string, such as `"openai:gpt-4o"`
    * `:data_source` - The data source name
    * `:context` - The caller-supplied context (or `nil`)
    * `:scope` - The caller-supplied scope (or `nil`)

  ### `[:lotus, :ai, :request, :stop]`

  Emitted when the model gives its final answer.

  **Measurements:** `:duration` (native units), `:prompt_tokens`,
  `:completion_tokens` and `:total_tokens`, summed over every round.

  **Metadata:** the start metadata plus:

    * `:usage` - The summed usage, as the AI functions return it
    * `:tool_calls` - The names of the tools the model called, in order and
      with repeats, such as `["list_tables", "describe_table"]`
    * `:iterations` - The number of rounds, each one call to the provider

  ### `[:lotus, :ai, :request, :exception]`

  Emitted when a call to the provider fails. The rounds before it were
  billed, so their usage is reported.

  **Measurements:** `:duration`, and the summed tokens as on `:stop`.

  **Metadata:** the stop metadata plus:

    * `:reason` - The error the caller receives

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

  @run_start [:lotus, :run, :start]
  @run_stop [:lotus, :run, :stop]
  @run_exception [:lotus, :run, :exception]

  @query_start [:lotus, :query, :start]
  @query_stop [:lotus, :query, :stop]
  @query_exception [:lotus, :query, :exception]

  @cache_hit [:lotus, :cache, :hit]
  @cache_miss [:lotus, :cache, :miss]
  @cache_put [:lotus, :cache, :put]

  @schema_start [:lotus, :schema, :introspection, :start]
  @schema_stop [:lotus, :schema, :introspection, :stop]

  @content_change_start [:lotus, :content, :change, :start]
  @content_change_stop [:lotus, :content, :change, :stop]
  @content_change_exception [:lotus, :content, :change, :exception]

  @ai_request_start [:lotus, :ai, :request, :start]
  @ai_request_stop [:lotus, :ai, :request, :stop]
  @ai_request_exception [:lotus, :ai, :request, :exception]

  @doc false
  def events do
    [
      @run_start,
      @run_stop,
      @run_exception,
      @query_start,
      @query_stop,
      @query_exception,
      @cache_hit,
      @cache_miss,
      @cache_put,
      @schema_start,
      @schema_stop,
      @content_change_start,
      @content_change_stop,
      @content_change_exception,
      @ai_request_start,
      @ai_request_stop,
      @ai_request_exception
    ]
  end

  @doc false
  def run_start(metadata) do
    start_time = System.monotonic_time()
    :telemetry.execute(@run_start, %{system_time: System.system_time()}, metadata)
    start_time
  end

  @doc false
  def run_stop(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @run_stop,
      %{duration: duration, row_count: metadata[:row_count] || 0},
      metadata
    )
  end

  @doc false
  def run_exception(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @run_exception,
      %{duration: duration},
      Map.put_new(metadata, :kind, :error)
    )
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
  def content_change_start(metadata) do
    start_time = System.monotonic_time()
    :telemetry.execute(@content_change_start, %{system_time: System.system_time()}, metadata)
    start_time
  end

  @doc false
  def content_change_stop(start_time, metadata) do
    duration = System.monotonic_time() - start_time
    :telemetry.execute(@content_change_stop, %{duration: duration}, metadata)
  end

  @doc false
  def content_change_exception(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @content_change_exception,
      %{duration: duration},
      Map.put_new(metadata, :kind, :error)
    )
  end

  @doc false
  def ai_request_start(metadata) do
    start_time = System.monotonic_time()
    :telemetry.execute(@ai_request_start, %{system_time: System.system_time()}, metadata)
    start_time
  end

  @doc false
  def ai_request_stop(start_time, metadata) do
    :telemetry.execute(@ai_request_stop, ai_measurements(start_time, metadata), metadata)
  end

  @doc false
  def ai_request_exception(start_time, metadata) do
    :telemetry.execute(@ai_request_exception, ai_measurements(start_time, metadata), metadata)
  end

  defp ai_measurements(start_time, metadata) do
    usage = Map.get(metadata, :usage) || %{}

    %{
      duration: System.monotonic_time() - start_time,
      prompt_tokens: Map.get(usage, :prompt_tokens, 0),
      completion_tokens: Map.get(usage, :completion_tokens, 0),
      total_tokens: Map.get(usage, :total_tokens, 0)
    }
  end

  @doc false
  def schema_introspection_start(operation, source) do
    start_time = System.monotonic_time()

    :telemetry.execute(@schema_start, %{system_time: System.system_time()}, %{
      operation: operation,
      source: source
    })

    start_time
  end

  @doc false
  def schema_introspection_stop(start_time, operation, source, result_status) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(@schema_stop, %{duration: duration}, %{
      operation: operation,
      source: source,
      result: result_status
    })
  end
end
