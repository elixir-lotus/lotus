defmodule Lotus.Runner do
  @moduledoc """
  Statement execution with safety checks, param binding, and result shaping.

  By default, all statements are read-only. Destructive operations (writes,
  schema changes — INSERT, UPDATE, DELETE and DDL in SQL terms) are blocked
  at both the application and database level. Pass `read_only: false` to
  allow write operations.

  What counts as a write is the adapter's judgement, via
  `c:Lotus.Source.Adapter.sanitize_query/3`.
  """

  alias Lotus.{Middleware, Preflight, Result, Telemetry, Value, Visibility}
  alias Lotus.Preflight.Relations
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Visibility.Policy

  @type query_result :: Result.t()
  @type opts :: [
          timeout: non_neg_integer(),
          statement_timeout_ms: non_neg_integer(),
          read_only: boolean(),
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
  Where a result came from: executed against the source, or served from the
  result cache.
  """
  @type origin :: :executed | :cached

  @typedoc """
  What executing a statement produced: the result, and the relations preflight
  proved the statement touches.

  This is the unit the result cache stores, so that a caller serving a result
  from the cache can still hand the relations to `:before_execute`.
  """
  @type execution :: %{result: query_result(), relations: relations()}

  @typedoc """
  What a run produced, as `:after_query` sees it: the statement that ran, its
  result, the relations, and where the result came from.
  """
  @type outcome :: %{
          statement: Statement.t(),
          result: query_result(),
          relations: relations(),
          origin: origin()
        }

  @typedoc """
  The execute step of a run: takes the statement `:before_query` returned and
  produces the outcome. `run/4` supplies one that executes against the source;
  a caller that caches executions supplies one that consults the cache first.
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
  4. `:after_query`.

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
              with :ok <- gate_cached(adapter, outcome, opts),
                   {:ok, %Result{} = res} <-
                     tag(:after_query, after_query(adapter, outcome, opts)) do
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
    tag(
      :before_execute,
      before_execute(adapter, outcome.statement, outcome.relations, :cached, opts)
    )
  end

  defp gate_cached(_adapter, _outcome, _opts), do: :ok

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
  preflight found for it — the same value `:before_execute` received — and the
  origin, `:executed` or `:cached`. It runs whether the result came from the
  cache or from the source. A plug that changes the result changes what this
  call returns; the stored entry keeps the raw execution.
  """
  @spec after_query(Adapter.t(), outcome(), opts()) :: {:ok, query_result()} | {:error, term()}
  def after_query(%Adapter{} = adapter, %{result: %Result{} = result} = outcome, opts \\ []) do
    payload = %{
      source: adapter.name,
      statement: outcome.statement,
      result: result,
      relations: outcome.relations,
      origin: outcome.origin,
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

  @doc """
  Runs the `:before_execute` pipeline for a statement and the relations it
  touches.

  `execute_statement/3` runs this itself, with the relations preflight just
  found and origin `:executed`. `run/4` runs it with the relations stored
  alongside a cached result and origin `:cached`, so the gate fires on every
  call: a plug that authorizes a statement against its tables is an access
  control, and an access control that a warm cache skips is no control at all.
  """
  @spec before_execute(Adapter.t(), Statement.t(), relations(), origin(), opts()) ::
          :ok | {:error, term()}
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
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    case Middleware.run(:before_execute, payload) do
      {:cont, _payload} -> :ok
      {:halt, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes a statement: sanitization, preflight, `:before_execute`, the query
  itself and column policy enforcement.

  Returns the result together with the relations preflight proved the statement
  touches, which is what the result cache stores — see `t:execution/0`. The
  query middleware around this phase lives in `before_query/3` and
  `after_query/4`, and `[:lotus, :query, *]` telemetry covers this phase only,
  so a statement served from the cache emits no query events.
  """
  @spec execute_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok, execution()} | {:error, term()}
  def execute_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    adapter
    |> execute_phases(statement, opts)
    |> untag()
  end

  @doc false
  # `execute_statement/3` with the failing phase named in the error, for
  # `run/4` and for an execute step that wraps this in the result cache. The
  # phase travels as `{:error, {Lotus.Runner, phase, reason}}`.
  @spec execute_phases(Adapter.t(), Statement.t(), opts()) ::
          {:ok, execution()} | {:error, {module(), atom(), term()}}
  def execute_phases(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    telemetry_meta = %{
      source: adapter.name,
      statement: statement,
      context: Keyword.get(opts, :context)
    }

    start_time = Telemetry.query_start(telemetry_meta)

    # Preflight hands its relations back as a value, and they travel down the
    # pipeline explicitly. Nothing crosses a statement boundary through the
    # process dictionary.
    result =
      with :ok <- tag(:sanitize, Adapter.sanitize_query(adapter, statement, sanitize_opts(opts))),
           {:ok, relations} <- tag(:preflight, preflight_visibility(adapter, statement, opts)),
           :ok <-
             tag(:before_execute, before_execute(adapter, statement, relations, :executed, opts)),
           {:ok, %Result{} = res} <-
             tag(:execute, exec_read_only(adapter, statement, relations, opts)) do
        {:ok, %{result: res, relations: relations}}
      end

    case result do
      {:ok, %{result: %Result{} = res}} ->
        Telemetry.query_stop(
          start_time,
          Map.merge(telemetry_meta, %{row_count: res.num_rows, result: res})
        )

        result

      {:error, _} = error ->
        Telemetry.query_exception(start_time, :error, untag(error), [], telemetry_meta)
        error
    end
  end

  defp vars(opts), do: Keyword.get(opts, :vars) || %{}

  defp exec_read_only(
         %Adapter{} = adapter,
         %Statement{body: body, params: params},
         relations,
         opts
       ) do
    Adapter.transaction(
      adapter,
      fn _state ->
        timeout = Keyword.get(opts, :timeout, 15_000)

        {elapsed_us, res} =
          :timer.tc(fn ->
            Adapter.execute_query(adapter, body, params, opts ++ [timeout: timeout])
          end)

        handle_query_result(res, elapsed_us, adapter, relations, Keyword.get(opts, :scope))
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

  defp handle_query_result(
         {:ok, %{columns: cols, rows: rows} = raw},
         elapsed_us,
         %Adapter{} = adapter,
         relations,
         scope
       ) do
    num_rows = Map.get(raw, :num_rows, length(rows || []))
    command = normalize_command(Map.get(raw, :command))
    duration_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

    rels = Relations.to_list(relations)

    policies =
      Enum.map(cols || [], fn c ->
        Visibility.column_policy_for(adapter.name, rels, c, scope)
      end)

    case enforce_column_policies(cols || [], rows || [], policies) do
      {:error, msg} ->
        {:error, msg}

      {final_cols, final_rows} ->
        result_meta =
          raw
          |> Map.take([:connection_id, :messages])
          |> maybe_put_total_count(raw)

        {:ok,
         Result.new(final_cols, final_rows,
           num_rows: num_rows,
           duration_ms: duration_ms,
           command: command,
           meta: result_meta
         )}
    end
  end

  defp handle_query_result({:error, err}, _elapsed_us, _adapter, _relations, _scope) do
    {:error, err}
  end

  defp handle_query_result(other, _elapsed_us, _adapter, _relations, _scope) do
    other
  end

  defp maybe_put_total_count(meta, %{total_count: n}) when is_integer(n) and n >= 0,
    do: Map.put(meta, :total_count, n)

  defp maybe_put_total_count(meta, _raw), do: meta

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
  defp apply_mask_policy(_value, %{mask: :null}), do: nil
  defp apply_mask_policy(_value, %{mask: {:fixed, fixed_value}}), do: fixed_value
  defp apply_mask_policy(value, %{mask: :sha256}), do: sha256_hex(to_string_safe(value))

  defp apply_mask_policy(value, %{mask: {:partial, opts}}),
    do: partial_mask(to_string_safe(value), opts)

  defp apply_mask_policy(_value, _), do: nil

  defp to_string_safe(nil), do: ""

  # Binaries stay as they are so a mask sees the stored bytes rather than a
  # rendering of them. Everything else — maps from `jsonb`, structs, tuples —
  # goes through the same display normalization the UI and exports use, since
  # `to_string/1` raises for most of them.
  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: Value.to_display_string(v)

  defp sha256_hex(s) do
    :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  end

  defp partial_mask(s, opts) when is_binary(s) do
    if String.valid?(s), do: partial_mask_text(s, opts), else: mask_every_byte(s, opts)
  end

  # Binary data that is not valid UTF-8 (`bytea`, for example) has no readable
  # prefix or suffix worth keeping, so none of it survives the mask.
  defp mask_every_byte(s, opts) do
    repl = Keyword.get(opts, :replacement, "*")
    String.duplicate(repl, byte_size(s))
  end

  defp partial_mask_text(s, opts) do
    keep_last = Keyword.get(opts, :keep_last, 4)
    keep_first = Keyword.get(opts, :keep_first, 0)
    repl = Keyword.get(opts, :replacement, "*")

    len = String.length(s)
    left = min(keep_first, len)
    right = min(keep_last, max(len - left, 0))
    mid = max(len - left - right, 0)

    if mid == 0 do
      String.duplicate(repl, len)
    else
      left_part = String.slice(s, 0, left)
      right_part = if right > 0, do: String.slice(s, len - right, right), else: ""
      left_part <> String.duplicate(repl, mid) <> right_part
    end
  end

  defp sanitize_opts(opts) do
    Keyword.take(opts, [:read_only])
  end

  # Returns what preflight knows about the statement: a list of
  # `{schema, table}`, `{:unrestricted, reason}` for an adapter that cannot
  # name them, or `{:skipped, reason}` for a statement the adapter does not
  # preflight — nothing was analysed, so nothing is known, and that is not the
  # same as an empty list.
  defp preflight_visibility(%Adapter{} = adapter, %Statement{} = statement, opts) do
    if Adapter.needs_preflight?(adapter, statement) do
      search_path = Keyword.get(opts, :search_path)
      scope = Keyword.get(opts, :scope)

      Preflight.analyze(adapter, statement, search_path, scope)
    else
      {:ok, {:skipped, "the adapter does not preflight this statement"}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
