defmodule Lotus.Diff do
  @moduledoc """
  How the rows of two queries differ, matched on a key: the rows only the
  second has (`added`), those only the first has (`removed`), and those
  both have whose values differ (`changed`).

      {:ok, diff} =
        Lotus.diff({pinned_query, vars: %{"status" => "pending"}}, {query, []},
          key: ["id"])

      diff.added      #=> rows of the second query, as maps of column => value
      diff.removed    #=> rows of the first
      diff.changed    #=> [%{key: [42], before: %{…}, after: %{…}, columns: ["total"]}]

  Both queries run now, through `Lotus.run_query/2`, so visibility,
  middleware and the source's settings apply as to any run, read only. Each
  may return up to `:limit` rows (`#{10_000}` by default); a query that
  returns more is `{:error, {:too_many_rows, limit}}`: compare fewer rows
  (a narrower filter) or raise the limit.

  The key is one column or several, which both results have and which is
  unique in each (`{:error, {:duplicate_key, :before | :after, key}}`
  when it is not). `changed` compares the columns both results have.
  """

  alias Lotus.Result

  @default_limit 10_000

  defstruct key: [],
            columns: [],
            added: [],
            removed: [],
            changed: [],
            unchanged: 0,
            before_count: 0,
            after_count: 0

  @type row :: %{String.t() => term()}
  @type t :: %__MODULE__{
          key: [String.t()],
          columns: [String.t()],
          added: [row()],
          removed: [row()],
          changed: [%{key: [term()], before: row(), after: row(), columns: [String.t()]}],
          unchanged: non_neg_integer(),
          before_count: non_neg_integer(),
          after_count: non_neg_integer()
        }

  @type side :: {Lotus.Storage.Query.t(), keyword()}

  @doc """
  Runs both queries and compares their rows on `:key` (a column or a list
  of them). Each side is `{query, opts}`: its own options of
  `Lotus.run_query/2` (`:vars`, `:search_path`). `opts` go to both runs
  (`:context`, `:scope`, `:repo`), plus `:key` and `:limit`.
  """
  @spec run(side(), side(), keyword()) :: {:ok, t()} | {:error, term()}
  def run({before_query, before_opts}, {after_query, after_opts}, opts) do
    {key, opts} = Keyword.pop(opts, :key)
    {limit, opts} = Keyword.pop(opts, :limit, @default_limit)

    with {:ok, key} <- key(key),
         {:ok, before} <- fetch(before_query, before_opts, opts, limit),
         {:ok, after_} <- fetch(after_query, after_opts, opts, limit) do
      compare(before, after_, key)
    end
  end

  defp key(column) when is_binary(column) and column != "", do: {:ok, [column]}
  defp key([_ | _] = columns), do: {:ok, Enum.map(columns, &to_string/1)}
  defp key(_), do: {:error, :no_key}

  defp fetch(query, side_opts, opts, limit) do
    run_opts =
      opts
      |> Keyword.merge(side_opts)
      |> Keyword.merge(read_only: true, window: [limit: limit + 1, offset: 0, count: :none])

    case Lotus.run_query(query, run_opts) do
      {:ok, %Result{rows: rows}} when length(rows) > limit -> {:error, {:too_many_rows, limit}}
      other -> other
    end
  end

  @doc """
  Compares two results on `key`, a list of columns both have.
  """
  @spec compare(Result.t() | map(), Result.t() | map(), [String.t()]) ::
          {:ok, t()} | {:error, term()}
  def compare(before, after_, key) do
    with :ok <- has_key(before, key, :before),
         :ok <- has_key(after_, key, :after),
         {:ok, before_rows} <- index(before, key, :before),
         {:ok, after_rows} <- index(after_, key, :after) do
      columns = Enum.filter(after_.columns, &(&1 in before.columns))

      {changed, unchanged} =
        after_.rows
        |> Enum.map(&row_key(&1, after_.columns, key))
        |> Enum.filter(&Map.has_key?(before_rows, &1))
        |> Enum.map(fn k -> changes(k, before_rows[k], after_rows[k], columns) end)
        |> Enum.split_with(&match?(%{columns: [_ | _]}, &1))

      {:ok,
       %__MODULE__{
         key: key,
         columns: columns,
         added: only(after_, before_rows, key),
         removed: only(before, after_rows, key),
         changed: changed,
         unchanged: length(unchanged),
         before_count: length(before.rows),
         after_count: length(after_.rows)
       }}
    end
  end

  defp has_key(%{columns: columns}, key, side) do
    case Enum.reject(key, &(&1 in columns)) do
      [] -> :ok
      missing -> {:error, {:missing_key, side, missing}}
    end
  end

  # The rows of a result by their key, as maps.
  defp index(%{columns: columns, rows: rows}, key, side) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      k = row_key(row, columns, key)

      if Map.has_key?(acc, k),
        do: {:halt, {:error, {:duplicate_key, side, k}}},
        else: {:cont, {:ok, Map.put(acc, k, to_map(row, columns))}}
    end)
  end

  # The rows of `result`, in its order, whose key `other` does not have.
  defp only(%{columns: columns, rows: rows}, other, key) do
    for row <- rows, not Map.has_key?(other, row_key(row, columns, key)), do: to_map(row, columns)
  end

  defp changes(k, before, after_, columns) do
    differ = Enum.reject(columns, &same?(before[&1], after_[&1]))
    %{key: k, before: before, after: after_, columns: differ}
  end

  defp row_key(row, columns, key) do
    map = to_map(row, columns)
    Enum.map(key, &normalize(map[&1]))
  end

  defp to_map(row, columns), do: columns |> Enum.zip(row) |> Map.new()

  defp same?(a, b), do: normalize(a) == normalize(b)

  # Equal values of a column compare equal however the driver gave them:
  # 1.0 and 1.00, a date and its time at midnight are not mixed up.
  defp normalize(%Decimal{} = d), do: Decimal.normalize(d)
  defp normalize(n) when is_float(n) and trunc(n) == n, do: Decimal.new(trunc(n))
  defp normalize(n) when is_integer(n), do: Decimal.new(n)
  defp normalize(value), do: value
end
