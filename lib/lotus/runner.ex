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

  @doc """
  Runs a statement through the full pipeline: `:before_query`, sanitization,
  preflight, `:before_execute`, execution, column policy enforcement and
  `:after_query`.

  A caller that wraps execution in the result cache composes the three phases
  itself — `before_query/3`, `execute_statement/3`, `after_query/4` — so that
  the query middleware runs on a cache hit as well.
  """
  @spec run_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok, query_result()} | {:error, term()}
  def run_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    with {:ok, %Statement{} = statement} <- before_query(adapter, statement, opts),
         {:ok, %Result{} = res} <- execute_statement(adapter, statement, opts) do
      after_query(adapter, statement, res, opts)
    end
  end

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
  Runs the `:after_query` pipeline on a result and returns what it yields.

  A caller that caches the execution runs this phase on the returned result,
  whether that result came from the cache or from the source. A plug that
  changes the result changes what this call returns; the stored entry keeps the
  raw execution.
  """
  @spec after_query(Adapter.t(), Statement.t(), query_result(), opts()) ::
          {:ok, query_result()} | {:error, term()}
  def after_query(%Adapter{} = adapter, %Statement{} = statement, %Result{} = result, opts \\ []) do
    payload = %{
      source: adapter.name,
      statement: statement,
      result: result,
      context: Keyword.get(opts, :context),
      vars: vars(opts)
    }

    case Middleware.run(:after_query, payload) do
      {:cont, %{result: %Result{} = res}} -> {:ok, res}
      {:cont, _} -> {:ok, result}
      {:halt, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes a statement: sanitization, preflight, `:before_execute`, the query
  itself and column policy enforcement.

  This is the phase the result cache stores. The query middleware around it
  lives in `before_query/3` and `after_query/4`, and `[:lotus, :query, *]`
  telemetry covers this phase only — a statement served from the cache emits
  no query events.
  """
  @spec execute_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok, query_result()} | {:error, term()}
  def execute_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    context = Keyword.get(opts, :context)
    telemetry_meta = %{source: adapter.name, statement: statement, context: context}
    start_time = Telemetry.query_start(telemetry_meta)

    # Preflight records its relations in the process dictionary, and
    # `preflight_visibility/3` reads them out once and carries them down the
    # pipeline explicitly. Clearing on both sides keeps them from crossing a
    # statement boundary: on entry, because `Preflight.authorize/4` is public
    # and a caller may have left its own behind, and in `after` on every exit,
    # raises included, so a statement that fails cannot hand its tables to the
    # next one in the same process.
    result =
      try do
        Relations.clear()

        with :ok <- Adapter.sanitize_query(adapter, statement, sanitize_opts(opts)),
             {:ok, relations} <- preflight_visibility(adapter, statement, opts),
             :ok <- run_before_execute(adapter, statement, relations, context, vars(opts)),
             {:ok, %Result{} = res} <- exec_read_only(adapter, statement, relations, opts) do
          {:ok, res}
        end
      after
        Relations.clear()
      end

    case result do
      {:ok, %Result{} = res} ->
        Telemetry.query_stop(
          start_time,
          Map.merge(telemetry_meta, %{row_count: res.num_rows, result: res})
        )

        {:ok, res}

      {:error, _} = error ->
        Telemetry.query_exception(start_time, :error, error, [], telemetry_meta)
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

  # Fires once sanitization and preflight have passed, with the relations
  # preflight proved the statement touches. A plug may inspect but not rewrite
  # here — the statement has already been authorized, so the one that executes
  # must be the one preflight saw.
  defp run_before_execute(
         %Adapter{} = adapter,
         %Statement{} = statement,
         relations,
         context,
         vars
       ) do
    payload = %{
      source: adapter.name,
      statement: statement,
      relations: relations,
      context: context,
      vars: vars
    }

    case Middleware.run(:before_execute, payload) do
      {:cont, _payload} -> :ok
      {:halt, reason} -> {:error, reason}
    end
  end

  # Returns what preflight proved the statement touches: a list of
  # `{schema, table}`, or `{:unrestricted, reason}` for an adapter that cannot
  # name them. An adapter that needs no preflight yields `[]` — nothing was
  # analysed, so nothing is known.
  defp preflight_visibility(%Adapter{} = adapter, %Statement{} = statement, opts) do
    if Adapter.needs_preflight?(adapter, statement) do
      search_path = Keyword.get(opts, :search_path)
      scope = Keyword.get(opts, :scope)

      case Preflight.authorize(adapter, statement, search_path, scope) do
        :ok -> {:ok, Relations.get()}
        {:error, msg} -> {:error, msg}
      end
    else
      {:ok, []}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
