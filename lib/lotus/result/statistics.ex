defmodule Lotus.Result.Statistics do
  @moduledoc """
  Computes column-level statistics from in-memory query results.

  Operates entirely on the data already present in a `%Lotus.Result{}` struct,
  requiring no additional database queries. Statistics are computed per-column
  and vary based on the detected column type (numeric, string, or temporal).
  """

  alias Lotus.Result

  @type column_type :: :numeric | :string | :temporal | :unknown
  @type column_stats :: map()

  @doc """
  Computes statistics for a single column in the result set.

  Returns a map with `:type` and type-specific statistics keys.
  Returns `{:error, reason}` if the column is not found.
  """
  @spec compute(Result.t(), String.t()) :: {:ok, column_stats()} | {:error, String.t()}
  def compute(%Result{} = result, column_name) when is_binary(column_name) do
    case column_index(result.columns, column_name) do
      nil ->
        {:error, "column '#{column_name}' not found"}

      idx ->
        values = extract_column(result.rows, idx)
        type = detect_type(values)
        stats = compute_stats(type, values)
        {:ok, Map.put(stats, :type, type)}
    end
  end

  @doc """
  Computes statistics for all columns in the result set.

  Returns a map of `%{column_name => stats_map}`.
  """
  @spec compute_all(Result.t()) :: %{String.t() => column_stats()}
  def compute_all(%Result{columns: columns} = result) do
    Map.new(columns, fn col ->
      {:ok, stats} = compute(result, col)
      {col, stats}
    end)
  end

  @doc """
  Detects the column type from its values.

  Inspects non-nil values and returns `:numeric`, `:string`, `:temporal`, or `:unknown`.
  """
  @spec detect_column_type(Result.t(), String.t()) :: column_type() | {:error, String.t()}
  def detect_column_type(%Result{} = result, column_name) do
    case column_index(result.columns, column_name) do
      nil -> {:error, "column '#{column_name}' not found"}
      idx -> result.rows |> extract_column(idx) |> detect_type()
    end
  end

  # --- Column extraction ---

  defp column_index(columns, name) do
    Enum.find_index(columns, &(&1 == name))
  end

  defp extract_column(rows, idx) do
    Enum.map(rows, &Enum.at(&1, idx))
  end

  # --- Type detection ---

  defp detect_type(values) do
    values
    |> Enum.find(&(not is_nil(&1)))
    |> type_of()
  end

  defp type_of(nil), do: :unknown
  defp type_of(v) when is_number(v), do: :numeric
  defp type_of(%Decimal{}), do: :numeric
  defp type_of(v) when is_binary(v), do: :string
  defp type_of(v) when is_atom(v), do: :string
  defp type_of(%Date{}), do: :temporal
  defp type_of(%Time{}), do: :temporal
  defp type_of(%DateTime{}), do: :temporal
  defp type_of(%NaiveDateTime{}), do: :temporal
  defp type_of(_), do: :unknown

  # --- Stats computation by type ---

  defp compute_stats(:numeric, values), do: numeric_stats(values)
  defp compute_stats(:string, values), do: string_stats(values)
  defp compute_stats(:temporal, values), do: temporal_stats(values)
  defp compute_stats(:unknown, values), do: base_stats(values)

  # --- Base stats (shared across all types) ---

  defp base_stats(values) do
    total = length(values)
    {non_nil, nil_count} = partition_nil(values)
    distinct = non_nil |> Enum.uniq() |> length()

    %{
      count: total,
      null_count: nil_count,
      null_percentage: if(total > 0, do: Float.round(nil_count / total * 100, 2), else: 0.0),
      distinct_count: distinct
    }
  end

  # --- Numeric statistics ---

  defp numeric_stats(values) do
    base = base_stats(values)
    {non_nil, _} = partition_nil(values)
    numbers = Enum.map(non_nil, &to_float/1)

    if numbers == [] do
      Map.merge(base, %{min: nil, max: nil, avg: nil, median: nil, sum: nil, histogram: []})
    else
      sorted = Enum.sort(numbers)

      Map.merge(base, %{
        min: List.first(sorted),
        max: List.last(sorted),
        avg: Float.round(Enum.sum(sorted) / length(sorted), 4),
        median: compute_median(sorted),
        sum: Float.round(Enum.sum(sorted), 4),
        histogram: compute_histogram(sorted)
      })
    end
  end

  defp compute_median(sorted) do
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      Float.round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2, 4)
    else
      Enum.at(sorted, mid) |> Float.round(4)
    end
  end

  @histogram_bins 10
  defp compute_histogram(sorted) do
    min_val = List.first(sorted)
    max_val = List.last(sorted)

    if min_val == max_val do
      [%{bin_start: min_val, bin_end: max_val, count: length(sorted)}]
    else
      bin_width = (max_val - min_val) / @histogram_bins

      bins =
        for i <- 0..(@histogram_bins - 1) do
          bin_start = Float.round(min_val + i * bin_width, 4)
          bin_end = Float.round(min_val + (i + 1) * bin_width, 4)
          %{bin_start: bin_start, bin_end: bin_end, count: 0}
        end

      sorted
      |> Enum.reduce(bins, fn val, acc ->
        bin_idx = floor((val - min_val) / bin_width)
        bin_idx = min(bin_idx, @histogram_bins - 1)

        List.update_at(acc, bin_idx, fn bin ->
          %{bin | count: bin.count + 1}
        end)
      end)
    end
  end

  # --- String statistics ---

  defp string_stats(values) do
    base = base_stats(values)
    {non_nil, _} = partition_nil(values)
    strings = Enum.map(non_nil, &to_string/1)

    if strings == [] do
      Map.merge(base, %{min_length: nil, max_length: nil, top_values: []})
    else
      lengths = Enum.map(strings, &safe_length/1)

      top_values =
        strings
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_val, count} -> count end, :desc)
        |> Enum.take(10)
        |> Enum.map(fn {val, count} -> %{value: val, count: count} end)

      Map.merge(base, %{
        min_length: Enum.min(lengths),
        max_length: Enum.max(lengths),
        top_values: top_values
      })
    end
  end

  defp safe_length(s) do
    if String.valid?(s), do: String.length(s), else: byte_size(s)
  end

  # --- Temporal statistics ---

  defp temporal_stats(values) do
    base = base_stats(values)
    {non_nil, _} = partition_nil(values)

    if non_nil == [] do
      Map.merge(base, %{earliest: nil, latest: nil, distribution: []})
    else
      sorted = Enum.sort(non_nil, &temporal_lte?/2)

      Map.merge(base, %{
        earliest: List.first(sorted),
        latest: List.last(sorted),
        distribution: compute_temporal_distribution(sorted)
      })
    end
  end

  defp temporal_lte?(a, b) do
    case {a, b} do
      {%DateTime{}, %DateTime{}} -> DateTime.compare(a, b) != :gt
      {%NaiveDateTime{}, %NaiveDateTime{}} -> NaiveDateTime.compare(a, b) != :gt
      {%Date{}, %Date{}} -> Date.compare(a, b) != :gt
      {%Time{}, %Time{}} -> Time.compare(a, b) != :gt
      _ -> to_string(a) <= to_string(b)
    end
  end

  defp compute_temporal_distribution(sorted) do
    sorted
    |> Enum.map(&temporal_bucket/1)
    |> Enum.frequencies()
    |> Enum.sort()
    |> Enum.map(fn {bucket, count} -> %{bucket: bucket, count: count} end)
  end

  defp temporal_bucket(%Date{} = d), do: "#{d.year}-#{pad(d.month)}"
  defp temporal_bucket(%DateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}"
  defp temporal_bucket(%NaiveDateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}"
  defp temporal_bucket(%Time{} = t), do: "#{pad(t.hour)}:00"
  defp temporal_bucket(other), do: to_string(other)

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  # --- Helpers ---

  defp partition_nil(values) do
    {non_nil, nils} = Enum.split_with(values, &(not is_nil(&1)))
    {non_nil, length(nils)}
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_integer(n), do: n / 1
  defp to_float(n) when is_float(n), do: n
end
