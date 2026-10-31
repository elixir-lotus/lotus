defmodule Lotus.Runner do
  @moduledoc """
  Statement execution with safety checks, param binding, and result shaping.

  By default, all statements are read-only. Destructive operations (writes,
  schema changes — INSERT, UPDATE, DELETE and DDL in SQL terms) are blocked
  at both the application and database level. Pass `read_only: false` to
  allow write operations.

  What counts as a write is the adapter's judgement, via
  `c:Lotus.Source.Adapter.Preflight.sanitize_query/3`. `writes?/2` asks it
  without running the statement.

  A statement on a source that declares `Lotus.Source.Adapter.Cancel` can be
  stopped while it runs: pass `on_cancel_token: fun`, and give the token
  `fun` receives to `Lotus.cancel/1`. See `Lotus.Runner.Cancel`.
  """

  alias Lotus.{Middleware, Preflight, Result, Telemetry, Visibility}
  alias Lotus.Preflight.{Columns, Relations}
  alias Lotus.Query.Statement
  alias Lotus.Runner.Cancel
  alias Lotus.Source.Adapter
  alias Lotus.Visibility.{Mask, Matcher, Policy}

  @type query_result :: Result.t()
  @type opts :: [
          timeout: non_neg_integer(),
          statement_timeout_ms: non_neg_integer(),
          read_only: boolean(),
          on_cancel_token: (Cancel.t() -> any()),
          search_path: String.t() | nil,
          scope: term(),
          context: term(),
          vars: map()
        ]

  @typedoc """
  What preflight knows about the relations a statement touches.

  A list is a proven set of `{schema, table}` pairs, and an empty list means
  the statement touches no relation (`SELECT 1`). A tuple means nothing is
  known: `{:unrestricted, reason}` when the adapter cannot name relations and
  the host opted in, `{:skipped, reason}` when the adapter does not preflight
  the statement at all. A plug that gates on tables matches `when is_list/1`
  and treats any tuple as unknown.
  """
  @type relations :: Relations.outcome()

  @typedoc """
  Where a result came from: executed against the source, served from the
  result cache, or one chunk of a stream (`stream/4`).
  """
  @type origin :: :executed | :cached | :streamed

  @typedoc """
  What executing a statement produced: the result, and the relations preflight
  proved the statement touches.

  This is the unit the result cache stores, so that a caller serving a result
  from the cache can still hand the relations to `:before_execute`, and the
  source of each result column to `:after_query` (see `t:column_sources/0`).
  """
  @type execution :: %{
          required(:result) => query_result(),
          required(:relations) => relations(),
          optional(:column_sources) => column_sources()
        }

  @typedoc """
  Where each column of a result comes from, by position: one entry per
  column of the result, in its order, after the column policies dropped the
  columns they omit. `{:relation, {schema, table}}` is a column the column
  check traced to that relation for sure (a qualified column as is, such as
  `u.ssn` or `u.ssn AS ssn`, under a qualifier that names one relation);
  `:unresolved` is any other (an expression, an unqualified name over more
  than one relation, a column at or after a `*`, every column of a set
  operation). A statement that only selects `*` from one derived table or
  CTE (the wrappers of `window:`, `filters:` and `sorts:`) has the sources
  of the statement inside. See `Lotus.Preflight.Columns.result_sources/4`.

  A plug that applies column rules of its own applies a traced column's own
  relation's rule, and to an `:unresolved` column the strictest rule any of
  the relations has for its name, as Lotus does for its column policies.
  """
  @type column_sources :: [Columns.source()]

  @typedoc """
  What the `:before_execute` plugs of a call left under `:assigns`, handed to
  the `:after_query` plugs of the same call. It belongs to that call alone, so
  the result cache never stores it.
  """
  @type assigns :: map()

  @typedoc """
  What authorizing a statement produced: the relations preflight proved it
  touches, the assigns its `:before_execute` plugs left, the fingerprint of
  the visibility rules it was checked against (see `rules_fingerprint/2`),
  and the relation each result column comes from, when the column check
  could tell (see `Lotus.Preflight.Columns.result_sources/4`).
  """
  @type authorization :: %{
          required(:relations) => relations(),
          required(:assigns) => assigns(),
          required(:rules) => binary(),
          optional(:columns) => Columns.sources()
        }

  @typedoc """
  What a run produced, as `:after_query` sees it: the statement that ran, its
  result, the relations, where the result came from, the assigns of
  `:before_execute`, and the source of each result column, when known.
  """
  @type outcome :: %{
          required(:statement) => Statement.t(),
          required(:result) => query_result(),
          required(:relations) => relations(),
          required(:origin) => origin(),
          optional(:assigns) => assigns(),
          optional(:column_sources) => column_sources()
        }

  @typedoc """
  The execute step of a run: takes the statement `:before_query` returned and
  produces the outcome. `run/4` supplies one that executes against the source;
  a caller that caches executions supplies one that consults the cache first.

  A step that reports origin `:executed` has run `:before_execute` and returns
  its assigns. A step that reports `:cached` has not, and returns none: `run/4`
  runs the gate and takes the assigns from it.
  """
  @type executor :: (Statement.t() -> {:ok, outcome()} | {:error, term()})

  @phases [:before_query, :sanitize, :preflight, :before_execute, :execute, :after_query]

  @doc """
  Runs a statement through the full pipeline: `:before_query`, sanitization,
  preflight, `:before_execute`, execution, column policy enforcement and
  `:after_query`. See `run/4`.
  """
  @spec run_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok, query_result()} | {:error, term()}
  def run_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    run(adapter, statement, opts, nil)
  end

  @doc """
  Runs the phases of a statement run around an execute step.

  This is the one place the phase order lives. `run_statement/3` uses it with
  the default step, which executes against the source; `Lotus` uses it with a
  step that consults the result cache. Both get the same phases, the same
  payloads and the same telemetry:

  1. `:before_query`, which may rewrite the statement.
  2. The execute step, with the statement `:before_query` returned. The default
     step is `execute_statement/3`, which runs sanitization, preflight and
     `:before_execute` itself.
  3. `:before_execute`, when the step served a cached result — the relations
     stored with the entry stand in for preflight, so the gate fires on a hit
     as it does on a miss.
  4. `:after_query`, with the assigns `:before_execute` left on this call.

  `[:lotus, :run, *]` telemetry brackets all of it: `:start` before the first
  phase, `:stop` after `:after_query` with the origin and the relations, and
  `:exception` when any phase fails, with the `:phase` that failed. It fires on
  a cache hit and on a halt alike, so a consumer that records who ran what and
  whether it was refused attaches to these three events and nothing else.

  A step may return `{:error, {Lotus.Runner, phase, reason}}` to name the phase
  that failed; the caller receives `{:error, reason}`.
  """
  @spec run(Adapter.t(), Statement.t(), opts(), executor() | nil) ::
          {:ok, query_result()} | {:error, term()}
  def run(%Adapter{} = adapter, %Statement{} = statement, opts, executor \\ nil) do
    executor = executor || default_executor(adapter, opts)

    meta = %{
      source: adapter.name,
      statement: statement,
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    start_time = Telemetry.run_start(meta)

    try do
      case tag(:before_query, before_query(adapter, statement, opts)) do
        {:ok, %Statement{} = statement} ->
          case executor.(statement) do
            {:ok, %{statement: %Statement{}, result: %Result{}} = outcome} ->
              with {:ok, gated} <- gate_cached(adapter, outcome, opts),
                   {:ok, %Result{} = res} <-
                     tag(:after_query, after_query(adapter, gated, opts)) do
                {:ok, res}
              end
              |> finish(start_time, meta, outcome)

            {:error, _} = error ->
              finish(error, start_time, meta, nil)
          end

        {:error, _} = error ->
          finish(error, start_time, meta, nil)
      end
    rescue
      e ->
        # Plugs that raise become halts inside `Middleware.run/2`, and the
        # execute step rescues adapter errors, so a raise here is exceptional.
        # The span still closes, so a consumer never sees a start without an
        # end, and the raise reaches the caller as it would have.
        Telemetry.run_exception(
          start_time,
          Map.merge(meta, %{phase: :unknown, reason: e, kind: :error, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    end
  end

  @default_chunk_size 1_000

  @doc """
  Streams a statement's rows to `fun`, chunk by chunk, without holding the
  whole result.

  The statement goes through the same phases as `run/4`: `:before_query`,
  sanitization, preflight, `:before_execute` and the session settings, all
  before the first row. `fun` then receives an `Enumerable` of
  `%Lotus.Result{}` chunks of at most `:chunk_size` rows (default 1000),
  each with the column policies applied and passed through `:after_query`
  with origin `:streamed`, so a plug that masks values masks every chunk.

  `fun` runs inside the statement's transaction, and the stream is only
  valid while it runs: consume it there, and return what you need. The call
  returns `{:ok, fun_result}`, or `{:error, reason}` when a phase before the
  first row refuses the statement, or a chunk's column policies or an
  `:after_query` plug refuse a chunk (the rows already handed to `fun`
  stay handed). An error of the source while rows are read raises, as
  `c:Ecto.Repo.stream/2` does.

  An adapter that declares `Lotus.Source.Adapter.Streaming` reads the rows
  from the source as `fun` consumes them. Any other runs the statement once
  and hands its rows over in chunks, so the API is the same and only the
  memory differs. Streams bypass the result cache.

  `[:lotus, :run, *]` and `[:lotus, :query, *]` telemetry bracket the stream,
  with origin `:streamed` and the number of rows streamed as `:row_count`.

  `opts` takes those of `run/4`, plus `:chunk_size`. `:timeout` is the time
  the whole stream may take, `:infinity` by default; the per-statement
  timeout still applies to each read.
  """
  @spec stream(Adapter.t(), Statement.t(), opts(), (Enumerable.t() -> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def stream(%Adapter{} = adapter, %Statement{} = statement, opts, fun)
      when is_function(fun, 1) do
    opts = Keyword.put_new(opts, :timeout, :infinity)

    meta = %{
      source: adapter.name,
      statement: statement,
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    start_time = Telemetry.run_start(meta)

    try do
      case tag(:before_query, before_query(adapter, statement, opts)) do
        {:ok, %Statement{} = statement} ->
          stream_authorized(adapter, statement, opts, fun, start_time, meta)

        {:error, _} = error ->
          finish(error, start_time, meta, nil)
      end
    rescue
      e ->
        # A source error while rows are read, or a raise in `fun`: the span
        # still closes, and the raise reaches the caller.
        Telemetry.run_exception(
          start_time,
          Map.merge(meta, %{phase: :execute, reason: e, kind: :error, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    end
  end

  defp stream_authorized(adapter, statement, opts, fun, start_time, meta) do
    outcome = %{statement: statement, relations: nil, origin: :streamed}

    case authorize_phases(adapter, statement, opts) do
      {:ok, %{relations: relations} = authorization} ->
        outcome = %{outcome | relations: relations}

        case stream_span(adapter, statement, authorization, opts, fun) do
          {:ok, value, summary} ->
            {:ok, _} = finish({:ok, summary}, start_time, meta, outcome)
            {:ok, value}

          {:error, _} = error ->
            finish(error, start_time, meta, outcome)
        end

      {:error, _} = error ->
        finish(error, start_time, meta, outcome)
    end
  end

  # The query span of a stream. Its stop carries the columns and the number
  # of rows streamed, as a result with no rows.
  defp stream_span(adapter, statement, authorization, opts, fun) do
    telemetry_meta = %{
      source: adapter.name,
      statement: statement,
      context: Keyword.get(opts, :context)
    }

    start_time = Telemetry.query_start(telemetry_meta)

    case stream_read_only(adapter, statement, authorization, opts, fun) do
      {:ok, value, %{columns: cols, rows: rows}} ->
        summary = Result.new(cols, [], num_rows: rows, meta: %{streamed: true})

        Telemetry.query_stop(
          start_time,
          Map.merge(telemetry_meta, %{row_count: rows, result: summary})
        )

        {:ok, value, summary}

      {:error, _} = error ->
        Telemetry.query_exception(start_time, :error, untag(error), [], telemetry_meta)
        error
    end
  end

  # The chunks are shaped as `fun` pulls them, inside the transaction. What
  # the span reports (the columns and the rows streamed) is kept in a table
  # private to this call, deleted when it returns.
  defp stream_read_only(adapter, statement, authorization, opts, fun) do
    %Statement{body: body, params: params, session: session} = statement
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    Adapter.transaction(
      adapter,
      fn _state ->
        with :ok <- tag(:execute, Adapter.setup_session(adapter, session, opts)),
             {:ok, raw} <- tag(:execute, open_stream(adapter, body, params, opts, chunk_size)) do
          ref = make_ref()
          tally = :ets.new(__MODULE__, [:set, :private])
          :ets.insert(tally, [{:columns, []}, {:rows, 0}])

          chunks =
            Stream.map(raw, fn chunk ->
              result = shape_chunk(adapter, statement, authorization, opts, chunk, ref)
              :ets.insert(tally, {:columns, result.columns})
              :ets.update_counter(tally, :rows, length(result.rows))
              result
            end)

          try do
            value = fun.(chunks)
            [{:columns, cols}] = :ets.lookup(tally, :columns)
            [{:rows, rows}] = :ets.lookup(tally, :rows)
            {:ok, value, %{columns: cols, rows: rows}}
          catch
            {^ref, phase, reason} -> {:error, {__MODULE__, phase, reason}}
          after
            :ets.delete(tally)
          end
        end
      end,
      opts
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> tag(:execute, {:error, reason})
    end
  end

  # The rows of a chunk with the column policies applied, through
  # `:after_query`. A refusal stops the stream: it is thrown to
  # `stream_read_only/5`, which returns it.
  defp shape_chunk(adapter, statement, authorization, opts, chunk, ref) do
    %{relations: relations, assigns: assigns} = authorization
    columns = {relations, Map.get(authorization, :columns)}
    scope = Keyword.get(opts, :scope)

    with {:ok, %{result: %Result{} = result, column_sources: column_sources}} <-
           tag(:execute, handle_query_result({:ok, chunk}, 0, adapter, columns, scope)),
         outcome = %{
           statement: statement,
           result: %{result | duration_ms: nil},
           relations: relations,
           origin: :streamed,
           assigns: assigns,
           column_sources: column_sources
         },
         {:ok, %Result{} = result} <- tag(:after_query, after_query(adapter, outcome, opts)) do
      result
    else
      {:error, {__MODULE__, phase, reason}} -> throw({ref, phase, reason})
    end
  end

  # The rows of the source, read as they are consumed when the adapter
  # streams; else the whole result, handed over in chunks.
  defp open_stream(adapter, body, params, opts, chunk_size) do
    if Adapter.capability?(adapter, :streaming) do
      Adapter.stream_query(adapter, body, params, Keyword.put(opts, :max_rows, chunk_size))
    else
      with {:ok, %{columns: cols, rows: rows} = raw} <-
             Adapter.execute_query(adapter, body, params, opts) do
        chunks =
          case rows || [] do
            [] ->
              [%{raw | rows: []}]

            rows ->
              rows |> Enum.chunk_every(chunk_size) |> Enum.map(&%{raw | columns: cols, rows: &1})
          end

        {:ok, chunks}
      end
    end
  end

  defp default_executor(%Adapter{} = adapter, opts) do
    fn %Statement{} = statement ->
      with {:ok, execution} <- execute_phases(adapter, statement, opts) do
        {:ok, Map.merge(execution, %{statement: statement, origin: :executed})}
      end
    end
  end

  # A step that served a cached result skipped preflight and, with it, the
  # gate. The relations stored with the entry make the gate possible here.
  defp gate_cached(%Adapter{} = adapter, %{origin: :cached} = outcome, opts) do
    with {:ok, assigns} <-
           tag(
             :before_execute,
             before_execute(adapter, outcome.statement, outcome.relations, :cached, opts)
           ) do
      {:ok, Map.put(outcome, :assigns, assigns)}
    end
  end

  defp gate_cached(_adapter, outcome, _opts), do: {:ok, outcome}

  defp finish({:ok, %Result{} = res}, start_time, meta, outcome) do
    Telemetry.run_stop(
      start_time,
      Map.merge(meta, %{
        statement: outcome.statement,
        result: res,
        row_count: res.num_rows,
        relations: outcome.relations,
        origin: outcome.origin
      })
    )

    {:ok, res}
  end

  defp finish({:error, {__MODULE__, phase, reason}}, start_time, meta, outcome) do
    Telemetry.run_exception(start_time, exception_meta(meta, phase, reason, outcome))
    {:error, reason}
  end

  defp finish({:error, reason}, start_time, meta, outcome) do
    Telemetry.run_exception(start_time, exception_meta(meta, :execute, reason, outcome))
    {:error, reason}
  end

  defp exception_meta(meta, phase, reason, nil),
    do: Map.merge(meta, %{phase: phase, reason: reason})

  defp exception_meta(meta, phase, reason, outcome) do
    Map.merge(meta, %{
      phase: phase,
      reason: reason,
      statement: outcome.statement,
      relations: outcome.relations,
      origin: outcome.origin
    })
  end

  # Names the phase an error came from, so the run span can report it. The
  # wrapper is unwrapped before anything reaches the caller.
  defp tag(phase, {:error, {__MODULE__, _phase, _reason}} = tagged) when phase in @phases,
    do: tagged

  defp tag(phase, {:error, reason}) when phase in @phases,
    do: {:error, {__MODULE__, phase, reason}}

  defp tag(_phase, other), do: other

  defp untag({:error, {__MODULE__, phase, reason}}) when phase in @phases, do: {:error, reason}
  defp untag(other), do: other

  @doc """
  Runs the `:before_query` pipeline and returns the statement to execute.

  `:before_query` runs first because a plug may rewrite the statement — that is
  the point of the hook, for row-level security and tenant predicates.
  Sanitization and preflight then apply to what will actually execute, rather
  than to the text the caller originally supplied.

  A caller that caches the execution runs this phase outside the cache
  callback, and builds the cache key from the statement returned here: a plug
  that varies on `:context` must see every call, not only the one that fills
  the cache, and two plugs that rewrite differently must not share an entry.
  """
  @spec before_query(Adapter.t(), Statement.t(), opts()) ::
          {:ok, Statement.t()} | {:error, term()}
  def before_query(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    payload = %{
      source: adapter.name,
      statement: statement,
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    # A plug that rewrites `:statement` in the payload has its version carried
    # forward; one that returns the payload untouched leaves the original in
    # place. Anything that is not a statement is ignored rather than trusted.
    case Middleware.run(:before_query, payload) do
      {:cont, %{statement: %Statement{} = rewritten}} -> {:ok, rewritten}
      {:cont, _} -> {:ok, statement}
      {:halt, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs the `:after_query` pipeline on an outcome and returns the result it
  yields.

  The payload carries the statement that ran, the result, the relations
  preflight found for it — the same value `:before_execute` received — the
  origin, `:executed` or `:cached`, the assigns the `:before_execute` plugs
  of this call left, `%{}` when the outcome has none, and under
  `:column_sources` the source of each column of the result (see
  `t:column_sources/0`). When the outcome carries no sources, or a list
  that does not match the result's columns, every column is `:unresolved`.
  It runs whether the result came from the cache or from the source. A plug
  that changes the result changes what this call returns; the stored entry
  keeps the raw execution.
  """
  @spec after_query(Adapter.t(), outcome(), opts()) :: {:ok, query_result()} | {:error, term()}
  def after_query(%Adapter{} = adapter, %{result: %Result{} = result} = outcome, opts \\ []) do
    payload = %{
      source: adapter.name,
      statement: outcome.statement,
      result: result,
      relations: outcome.relations,
      origin: outcome.origin,
      assigns: Map.get(outcome, :assigns, %{}),
      column_sources: column_sources(result, Map.get(outcome, :column_sources)),
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    # No fallback clause for a `:cont` without a `%Result{}` under `:result`: a
    # plug whose whole job is to rewrite the result must fail loudly when it
    # returns a shape that cannot be one, rather than have Lotus quietly serve
    # the result the plug meant to replace.
    case Middleware.run(:after_query, payload) do
      {:cont, %{result: %Result{} = res}} -> {:ok, res}
      {:halt, reason} -> {:error, reason}
    end
  end

  # One source per result column. A list that does not match the columns
  # (none stored with an older cache entry, or a step that changed them)
  # tells nothing about any column, so every one is `:unresolved`: a plug
  # then applies the strictest rule, never a looser one.
  defp column_sources(%Result{columns: columns}, sources)
       when is_list(columns) and is_list(sources) and length(columns) == length(sources),
       do: sources

  defp column_sources(%Result{columns: columns}, _sources),
    do: Enum.map(columns || [], fn _ -> :unresolved end)

  @doc """
  Runs the `:before_execute` pipeline for a statement and the relations it
  touches.

  `execute_statement/3` runs this itself, with the relations preflight just
  found and origin `:executed`. `run/4` runs it with the relations stored
  alongside a cached result and origin `:cached`, so the gate fires on every
  call: a plug that authorizes a statement against its tables is an access
  control, and an access control that a warm cache skips is no control at all.

  The payload starts with `assigns: %{}`. Returns the `:assigns` of the payload
  the last plug continued with, for `:after_query`; `%{}` when that value is not
  a map. The other keys a plug changes are ignored: `:before_execute` decides
  whether the statement proceeds, it does not rewrite it.
  """
  @spec before_execute(Adapter.t(), Statement.t(), relations(), origin(), opts()) ::
          {:ok, assigns()} | {:error, term()}
  def before_execute(
        %Adapter{} = adapter,
        %Statement{} = statement,
        relations,
        origin,
        opts \\ []
      )
      when origin in [:executed, :cached] do
    payload = %{
      source: adapter.name,
      statement: statement,
      relations: relations,
      origin: origin,
      assigns: %{},
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    case Middleware.run(:before_execute, payload) do
      {:cont, %{assigns: assigns}} when is_map(assigns) -> {:ok, assigns}
      {:cont, _payload} -> {:ok, %{}}
      {:halt, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes a statement: sanitization, preflight, `:before_execute`, the query
  itself and column policy enforcement.

  Returns the result, the relations preflight proved the statement touches and
  the assigns `:before_execute` left. The result cache stores the result and the
  relations only — see `t:execution/0`. The query middleware around this phase
  lives in `before_query/3` and `after_query/4`, and `[:lotus, :query, *]`
  telemetry covers this phase only, so a statement served from the cache emits
  no query events.
  """
  @spec execute_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok,
           %{
             required(:result) => query_result(),
             required(:relations) => relations(),
             required(:assigns) => assigns(),
             optional(atom()) => term()
           }}
          | {:error, term()}
  def execute_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    adapter
    |> execute_phases(statement, opts)
    |> untag()
  end

  @doc false
  # `execute_statement/3` with the failing phase named in the error, for
  # `run/4`. The phase travels as `{:error, {Lotus.Runner, phase, reason}}`.
  @spec execute_phases(Adapter.t(), Statement.t(), opts()) ::
          {:ok,
           %{
             required(:result) => query_result(),
             required(:relations) => relations(),
             required(:assigns) => assigns(),
             optional(atom()) => term()
           }}
          | {:error, {module(), atom(), term()}}
  def execute_phases(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    query_span(adapter, statement, opts, fn ->
      with {:ok, authorization} <- authorize_phases(adapter, statement, opts),
           {:ok, %{result: %Result{}} = executed} <-
             execute_authorized(adapter, statement, authorization, opts) do
        {:ok, Map.merge(authorization, executed)}
      end
    end)
  end

  @doc false
  # Sanitization, preflight and `:before_execute`: what decides whether a
  # statement may execute. A step that caches executions runs this before it
  # writes the cache, so the assigns stay with the call that produced them.
  @spec authorize_phases(Adapter.t(), Statement.t(), opts()) ::
          {:ok, authorization()} | {:error, {module(), atom(), term()}}
  def authorize_phases(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    # Preflight hands its relations back as a value, and they travel down the
    # pipeline explicitly. Nothing crosses a statement boundary through the
    # process dictionary.
    with {:ok, %{relations: relations, matcher: matcher, columns: columns}} <-
           check_phases(adapter, statement, opts),
         {:ok, assigns} <-
           tag(:before_execute, before_execute(adapter, statement, relations, :executed, opts)) do
      {:ok,
       %{
         relations: relations,
         assigns: assigns,
         rules: Matcher.fingerprint(matcher),
         columns: columns
       }}
    end
  end

  @doc false
  # The fingerprint of the visibility rules the caller's scope gets for the
  # source now. A cached result was checked, and its column policies applied,
  # under the rules of the call that stored it, so it is served only while
  # the fingerprint stored with it matches. Asks the resolver; queries no
  # database. `nil` when the resolver fails, which matches no entry.
  @spec rules_fingerprint(Adapter.t(), opts()) :: binary() | nil
  def rules_fingerprint(%Adapter{} = adapter, opts) do
    case matcher(adapter, opts) do
      {:ok, matcher} -> Matcher.fingerprint(matcher)
      {:error, _reason} -> nil
    end
  end

  @doc false
  # What execution checks before it asks middleware: sanitization, the
  # source's visibility, preflight and how the statement uses protected
  # columns. Returns preflight's relations, or the error execution gives.
  # `Lotus.AI.Actions.ValidateStatement` runs it so that validating a
  # statement reveals no more than running it would.
  @spec check_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok, relations()} | {:error, term()}
  def check_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    with {:ok, %{relations: relations}} <- adapter |> check_phases(statement, opts) |> untag(),
         do: {:ok, relations}
  end

  @doc """
  Whether a statement would change data, by the judgement that refuses it
  in read-only mode: `c:Lotus.Source.Adapter.Preflight.sanitize_query/3`
  refuses it with `read_only: true` and takes it with `read_only: false`.

  Does not run the statement. A statement refused either way (two
  statements, say) cannot run at all, so it does not write. An adapter
  without `Lotus.Source.Adapter.Preflight` refuses nothing, so nothing it
  runs counts as a write.
  """
  @spec writes?(Adapter.t(), Statement.t()) :: boolean()
  def writes?(%Adapter{} = adapter, %Statement{} = statement) do
    match?({:error, _}, Adapter.sanitize_query(adapter, statement, read_only: true)) and
      Adapter.sanitize_query(adapter, statement, read_only: false) == :ok
  end

  defp check_phases(adapter, statement, opts) do
    with :ok <- tag(:sanitize, Adapter.sanitize_query(adapter, statement, sanitize_opts(opts))),
         :ok <- tag(:preflight, source_visible(adapter, opts)),
         {:ok, matcher} <- tag(:preflight, matcher(adapter, opts)),
         {:ok, relations} <-
           tag(:preflight, preflight_visibility(adapter, statement, matcher, opts)),
         {:ok, columns} <- tag(:preflight, check_columns(adapter, statement, relations, matcher)) do
      {:ok, %{relations: relations, matcher: matcher, columns: columns}}
    end
  end

  @doc false
  # The query and column policy enforcement, for a statement
  # `authorize_phases/3` let through: with its authorization, a result
  # column gets its own relation's policy when the column check could tell
  # it; with the relations alone, the strictest any of them has. Returns the
  # result with the source of each of its columns.
  @spec execute_authorized(Adapter.t(), Statement.t(), authorization() | relations(), opts()) ::
          {:ok, %{result: query_result(), column_sources: column_sources()}}
          | {:error, {module(), atom(), term()}}
  def execute_authorized(adapter, statement, authorization, opts \\ [])

  def execute_authorized(
        %Adapter{} = adapter,
        %Statement{} = statement,
        %{relations: relations} = authorization,
        opts
      ) do
    columns = {relations, Map.get(authorization, :columns)}
    tag(:execute, exec_read_only(adapter, statement, columns, opts))
  end

  def execute_authorized(%Adapter{} = adapter, %Statement{} = statement, relations, opts),
    do: tag(:execute, exec_read_only(adapter, statement, {relations, nil}, opts))

  @doc false
  # `[:lotus, :query, *]` telemetry around `fun`, which authorizes and executes
  # the statement and returns its result under `:result`.
  @spec query_span(Adapter.t(), Statement.t(), opts(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def query_span(%Adapter{} = adapter, %Statement{} = statement, opts, fun) do
    telemetry_meta = %{
      source: adapter.name,
      statement: statement,
      context: Keyword.get(opts, :context)
    }

    start_time = Telemetry.query_start(telemetry_meta)

    case fun.() do
      {:ok, %{result: %Result{} = res}} = ok ->
        Telemetry.query_stop(
          start_time,
          Map.merge(telemetry_meta, %{row_count: res.num_rows, result: res})
        )

        ok

      {:error, _} = error ->
        Telemetry.query_exception(start_time, :error, untag(error), [], telemetry_meta)
        error
    end
  end

  defp vars(opts), do: Keyword.get(opts, :vars) || %{}

  # The statement's session settings are applied inside its transaction, so
  # they end with it; a source that cannot apply them does not run it. A
  # statement cancelled with `Lotus.cancel/1` is the cancelled error, whatever
  # its transaction returned.
  defp exec_read_only(%Adapter{} = adapter, %Statement{} = statement, columns, opts) do
    cancel = Cancel.prepare(adapter, opts)
    Cancel.result(cancel, exec_in_transaction(adapter, statement, columns, opts, cancel))
  end

  defp exec_in_transaction(
         adapter,
         %Statement{body: body, params: params, session: session},
         columns,
         opts,
         cancel
       ) do
    Adapter.transaction(
      adapter,
      fn _state ->
        with :ok <- Adapter.setup_session(adapter, session || %{}, opts),
             {elapsed_us, res} when is_integer(elapsed_us) <-
               timed_execute(cancel, adapter, body, params, opts) do
          handle_query_result(res, elapsed_us, adapter, columns, Keyword.get(opts, :scope))
        end
      end,
      opts
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Adapter.format_error(adapter, e)}
  end

  # The query, timed, and stoppable with `Lotus.cancel/1` when the caller
  # asked for a token (see `Lotus.Runner.Cancel`). A cancelled statement is
  # `{:error, reason}`.
  defp timed_execute(cancel, adapter, body, params, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    Cancel.run(cancel, opts, fn ->
      :timer.tc(fn ->
        Adapter.execute_query(adapter, body, params, opts ++ [timeout: timeout])
      end)
    end)
  end

  # `columns` is `{relations, sources}`: the relations preflight found, and
  # the relation each result column comes from (`Columns.sources()`).
  defp handle_query_result(
         {:ok, %{columns: cols, rows: rows} = raw},
         elapsed_us,
         %Adapter{} = adapter,
         {relations, sources},
         scope
       ) do
    num_rows = Map.get(raw, :num_rows, length(rows || []))
    command = normalize_command(Map.get(raw, :command))
    duration_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

    rels = Relations.to_list(relations)
    matcher = Visibility.matcher_for(adapter.name, scope)
    sources = pad_sources(cols || [], sources)
    policies = column_policies(matcher, cols || [], rels, sources)

    with :ok <- check_named_values(matcher, rels, cols || [], rows || []),
         {final_cols, final_rows} when is_list(final_cols) <-
           enforce_column_policies(cols || [], rows || [], policies) do
      result_meta =
        raw
        |> Map.take([:connection_id, :messages])
        |> maybe_put_total_count(raw)
        |> maybe_put_cost(raw)

      result =
        Result.new(final_cols, final_rows,
          num_rows: num_rows,
          duration_ms: duration_ms,
          command: command,
          meta: result_meta
        )

      {:ok, %{result: result, column_sources: kept_sources(sources, policies)}}
    end
  end

  defp handle_query_result({:error, err}, _elapsed_us, _adapter, _columns, _scope) do
    {:error, err}
  end

  defp handle_query_result(other, _elapsed_us, _adapter, _columns, _scope) do
    other
  end

  # Column policies apply by name, so under one each value of a row needs a
  # named column. A source that returns rows without their columns (or with
  # fewer) would hand the values over unprotected.
  defp check_named_values(_matcher, _rels, _cols, []), do: :ok

  defp check_named_values(matcher, rels, cols, [row | _]) do
    if is_list(row) and length(row) != length(cols) and Matcher.restricts_columns?(matcher, rels),
      do:
        {:error,
         "The source returned rows whose columns it didn't name, so Lotus can't apply " <>
           "column policies to them."},
      else: :ok
  end

  # One source per column: a column past the end of what the column check
  # told (at or after a `*`), or of a statement it told nothing about, is
  # `:unresolved`.
  defp pad_sources(cols, sources) do
    cols
    |> Enum.zip(Stream.concat(sources || [], Stream.repeatedly(fn -> :unresolved end)))
    |> Enum.map(&elem(&1, 1))
  end

  # A column the column check traced to its relation gets that relation's
  # policy; any other, the strictest of all the relations' for its name.
  defp column_policies(matcher, cols, rels, sources) do
    cols
    |> Enum.zip(sources)
    |> Enum.map(fn {col, source} ->
      Visibility.column_policy_for(matcher, source_relations(source, rels), col)
    end)
  end

  # The sources of the columns the policies keep, in the result's order.
  defp kept_sources(sources, policies) do
    for {source, policy} <- Enum.zip(sources, policies),
        not Policy.omits_column?(policy),
        do: source
  end

  defp source_relations({:relation, relation}, _rels), do: [relation]
  defp source_relations(:unresolved, rels), do: rels

  defp maybe_put_total_count(meta, %{total_count: n}) when is_integer(n) and n >= 0,
    do: Map.put(meta, :total_count, n)

  defp maybe_put_total_count(meta, _raw), do: meta

  @cost_counts [:bytes_scanned, :bytes_billed, :rows_scanned]

  # The cost keys Lotus knows, with non-negative values; an adapter's other
  # keys and bad values are dropped.
  defp maybe_put_cost(meta, %{cost: cost}) when is_map(cost) do
    known =
      for {key, value} <- cost,
          (key in @cost_counts and is_integer(value) and value >= 0) or
            (key == :credits and is_number(value) and value >= 0),
          into: %{},
          do: {key, value}

    if known == %{}, do: meta, else: Map.put(meta, :cost, known)
  end

  defp maybe_put_cost(meta, _raw), do: meta

  defp normalize_command(nil), do: nil
  defp normalize_command(cmd) when is_atom(cmd), do: Atom.to_string(cmd)
  defp normalize_command(cmd) when is_binary(cmd), do: cmd
  defp normalize_command(cmd), do: inspect(cmd)

  defp enforce_column_policies(cols, rows, policies) do
    error_cols =
      cols
      |> Enum.zip(policies)
      |> Enum.filter(fn {_c, pol} -> Policy.causes_error?(pol) end)
      |> Enum.map(fn {c, _} -> c end)

    if error_cols != [] do
      {:error, "Query selects hidden column(s): #{Enum.join(error_cols, ", ")}"}
    else
      omit_idx =
        policies
        |> Enum.with_index()
        |> Enum.filter(fn {pol, _i} -> Policy.omits_column?(pol) end)
        |> Enum.map(fn {_pol, i} -> i end)
        |> MapSet.new()

      mask_map = build_mask_map(policies)

      new_cols =
        cols
        |> Enum.with_index()
        |> Enum.reject(fn {_c, i} -> MapSet.member?(omit_idx, i) end)
        |> Enum.map(&elem(&1, 0))

      new_rows = Enum.map(rows, fn row -> process_row(row, omit_idx, mask_map) end)

      {new_cols, new_rows}
    end
  end

  defp build_mask_map(policies) do
    policies
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {pol, i}, acc ->
      if Policy.requires_mask?(pol), do: Map.put(acc, i, pol), else: acc
    end)
  end

  defp process_row(row, omit_idx, mask_map) do
    row
    |> Enum.with_index()
    |> Enum.reject(fn {_v, i} -> MapSet.member?(omit_idx, i) end)
    |> Enum.map(fn {v, i} -> apply_mask_policy(v, Map.get(mask_map, i)) end)
  end

  defp apply_mask_policy(value, nil), do: value
  defp apply_mask_policy(value, %{mask: strategy}), do: Mask.apply(value, strategy)
  defp apply_mask_policy(_value, _), do: nil

  defp sanitize_opts(opts) do
    Keyword.take(opts, [:read_only])
  end

  # One matcher for preflight and the column check; the result asks again,
  # as a cached result does without them.
  defp matcher(%Adapter{name: name}, opts) do
    {:ok, Visibility.matcher_for(name, Keyword.get(opts, :scope))}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp source_visible(%Adapter{name: name}, opts) do
    if Visibility.source_visible?(name, Keyword.get(opts, :scope)),
      do: :ok,
      else: {:error, "Data source #{inspect(name)} is not available"}
  end

  # Column policies apply by result column name, so a SQL statement that
  # renames or transforms a protected column is refused before it runs. On
  # success, the relation each result column comes from, when it can tell.
  # A statement preflight skipped (EXPLAIN, SHOW) returns no column values.
  defp check_columns(_adapter, _statement, {:skipped, _reason}, _matcher), do: {:ok, nil}

  defp check_columns(%Adapter{} = adapter, %Statement{body: body}, relations, matcher)
       when is_binary(body) do
    if String.starts_with?(Adapter.query_language(adapter), "sql") do
      Columns.result_sources(body, Adapter.lexical_profile(adapter), matcher, relations)
    else
      {:ok, nil}
    end
  end

  defp check_columns(_adapter, _statement, _relations, _matcher), do: {:ok, nil}

  # Returns what preflight knows about the statement: a list of
  # `{schema, table}`, `{:unrestricted, reason}` for an adapter that cannot
  # name them, or `{:skipped, reason}` for a statement the adapter does not
  # preflight — nothing was analysed, so nothing is known, and that is not the
  # same as an empty list.
  defp preflight_visibility(%Adapter{} = adapter, %Statement{} = statement, matcher, opts) do
    if Adapter.needs_preflight?(adapter, statement) do
      Preflight.analyze_with(adapter, statement, Keyword.get(opts, :search_path), matcher)
    else
      {:ok, {:skipped, "the adapter does not preflight this statement"}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
