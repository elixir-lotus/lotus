defmodule Lotus.Runner do
  @moduledoc """
  Statement execution with safety checks, param binding, and result shaping.

  By default, all statements are read-only. Destructive operations (INSERT,
  UPDATE, DELETE, DDL) are blocked at both the application and database level.
  Pass `read_only: false` to allow write operations.
  """

  alias Lotus.{Middleware, Preflight, Result, Telemetry, Visibility}
  alias Lotus.Preflight.Relations
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Visibility.Policy

  @type query_result :: Result.t()
  @type opts :: [
          timeout: non_neg_integer(),
          statement_timeout_ms: non_neg_integer(),
          read_only: boolean(),
          search_path: String.t() | nil
        ]

  @spec run_statement(Adapter.t(), Statement.t(), opts()) ::
          {:ok, query_result()} | {:error, term()}
  def run_statement(%Adapter{} = adapter, %Statement{} = statement, opts \\ []) do
    context = Keyword.get(opts, :context)
    telemetry_meta = %{repo: adapter.name, statement: statement, context: context}
    start_time = Telemetry.query_start(telemetry_meta)

    result =
      with :ok <- Adapter.sanitize_query(adapter, statement, sanitize_opts(opts)),
           :ok <- preflight_visibility(adapter, statement, opts),
           :ok <- run_before_query(adapter, statement, context),
           {:ok, %Result{} = res} <- exec_read_only(adapter, statement, opts),
           {:ok, %Result{} = res} <- run_after_query(adapter, statement, res, context) do
        {:ok, res}
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

  defp exec_read_only(%Adapter{} = adapter, %Statement{text: sql, params: params}, opts) do
    Adapter.transaction(
      adapter,
      fn _state ->
        timeout = Keyword.get(opts, :timeout, 15_000)

        {elapsed_us, res} =
          :timer.tc(fn ->
            Adapter.execute_query(adapter, sql, params, opts ++ [timeout: timeout])
          end)

        handle_query_result(res, elapsed_us, adapter)
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
         %Adapter{} = adapter
       ) do
    num_rows = Map.get(raw, :num_rows, length(rows || []))
    command = normalize_command(Map.get(raw, :command))
    duration_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

    rels = Relations.take()

    policies =
      Enum.map(cols || [], fn c -> Visibility.column_policy_for(adapter.name, rels, c) end)

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

  defp handle_query_result({:error, err}, _elapsed_us, _adapter) do
    {:error, err}
  end

  defp handle_query_result(other, _elapsed_us, _adapter) do
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
  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: to_string(v)

  defp sha256_hex(s) do
    :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  end

  defp partial_mask(s, opts) when is_binary(s) do
    keep_last = Keyword.get(opts, :keep_last, 4)
    keep_first = Keyword.get(opts, :keep_first, 0)
    repl = Keyword.get(opts, :replacement, "*")

    len = String.length(s)
    left = min(keep_first, len)
    right = min(keep_last, max(len - left, 0))
    mid = max(len - left - right, 0)

    left_part = String.slice(s, 0, left)
    right_part = if right > 0, do: String.slice(s, len - right, right), else: ""
    masked = String.duplicate(repl, mid)
    left_part <> masked <> right_part
  end

  defp sanitize_opts(opts) do
    Keyword.take(opts, [:read_only])
  end

  defp run_before_query(%Adapter{} = adapter, %Statement{} = statement, context) do
    payload = %{source: adapter.name, statement: statement, context: context}

    case Middleware.run(:before_query, payload) do
      {:cont, _} -> :ok
      {:halt, reason} -> {:error, reason}
    end
  end

  defp run_after_query(
         %Adapter{} = adapter,
         %Statement{} = statement,
         %Result{} = result,
         context
       ) do
    payload = %{source: adapter.name, statement: statement, result: result, context: context}

    case Middleware.run(:after_query, payload) do
      {:cont, %{result: res}} -> {:ok, res}
      {:halt, reason} -> {:error, reason}
    end
  end

  defp preflight_visibility(%Adapter{} = adapter, %Statement{} = statement, opts) do
    if Adapter.needs_preflight?(adapter, statement) do
      search_path = Keyword.get(opts, :search_path)

      case Preflight.authorize(adapter, statement, search_path) do
        :ok -> :ok
        {:error, msg} -> {:error, msg}
      end
    else
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
