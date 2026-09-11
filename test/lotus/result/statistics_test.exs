defmodule Lotus.Result.StatisticsTest do
  use ExUnit.Case, async: true

  alias Lotus.Result
  alias Lotus.Result.Statistics

  # --- Helpers ---

  defp result(columns, rows) do
    Result.new(columns, rows)
  end

  # --- compute/2 ---

  describe "compute/2" do
    test "returns error for unknown column" do
      r = result(["a"], [[1]])
      assert {:error, "column 'missing' not found"} = Statistics.compute(r, "missing")
    end

    test "computes numeric stats" do
      r = result(["val"], [[10], [20], [30], [nil], [40]])
      assert {:ok, stats} = Statistics.compute(r, "val")

      assert stats.type == :numeric
      assert stats.count == 5
      assert stats.null_count == 1
      assert stats.null_percentage == 20.0
      assert stats.distinct_count == 4
      assert stats.min == 10.0
      assert stats.max == 40.0
      assert stats.avg == 25.0
      assert stats.median == 25.0
      assert stats.sum == 100.0
      assert is_list(stats.histogram)
    end

    test "computes string stats" do
      r = result(["name"], [["Alice"], ["Bob"], ["Alice"], [nil], ["Charlie"]])
      assert {:ok, stats} = Statistics.compute(r, "name")

      assert stats.type == :string
      assert stats.count == 5
      assert stats.null_count == 1
      assert stats.distinct_count == 3
      assert stats.min_length == 3
      assert stats.max_length == 7

      top = stats.top_values
      assert length(top) == 3
      assert %{value: "Alice", count: 2} = hd(top)
    end

    test "computes temporal stats" do
      dates = [~D[2024-01-15], ~D[2024-03-10], ~D[2024-01-20], nil]
      r = result(["date"], Enum.map(dates, &[&1]))
      assert {:ok, stats} = Statistics.compute(r, "date")

      assert stats.type == :temporal
      assert stats.earliest == ~D[2024-01-15]
      assert stats.latest == ~D[2024-03-10]
      assert stats.null_count == 1
      assert is_list(stats.distribution)
    end

    test "handles all-nil column" do
      r = result(["x"], [[nil], [nil]])
      assert {:ok, stats} = Statistics.compute(r, "x")

      assert stats.type == :unknown
      assert stats.null_count == 2
      assert stats.distinct_count == 0
    end
  end

  # --- compute_all/1 ---

  describe "compute_all/1" do
    test "computes stats for every column" do
      r = result(["id", "name"], [[1, "Alice"], [2, "Bob"]])
      all = Statistics.compute_all(r)

      assert Map.has_key?(all, "id")
      assert Map.has_key?(all, "name")
      assert all["id"].type == :numeric
      assert all["name"].type == :string
    end

    test "returns empty map for empty columns" do
      r = result([], [])
      assert %{} == Statistics.compute_all(r)
    end
  end

  # --- detect_column_type/2 ---

  describe "detect_column_type/2" do
    test "detects numeric" do
      r = result(["a"], [[42]])
      assert :numeric == Statistics.detect_column_type(r, "a")
    end

    test "detects string" do
      r = result(["a"], [["hello"]])
      assert :string == Statistics.detect_column_type(r, "a")
    end

    test "detects temporal from Date" do
      r = result(["a"], [[~D[2024-01-01]]])
      assert :temporal == Statistics.detect_column_type(r, "a")
    end

    test "detects temporal from DateTime" do
      r = result(["a"], [[~U[2024-01-01 00:00:00Z]]])
      assert :temporal == Statistics.detect_column_type(r, "a")
    end

    test "detects temporal from NaiveDateTime" do
      r = result(["a"], [[~N[2024-01-01 00:00:00]]])
      assert :temporal == Statistics.detect_column_type(r, "a")
    end

    test "detects numeric from Decimal" do
      r = result(["a"], [[Decimal.new("3.14")]])
      assert :numeric == Statistics.detect_column_type(r, "a")
    end

    test "skips leading nils" do
      r = result(["a"], [[nil], [nil], [42]])
      assert :numeric == Statistics.detect_column_type(r, "a")
    end

    test "returns unknown for all nils" do
      r = result(["a"], [[nil], [nil]])
      assert :unknown == Statistics.detect_column_type(r, "a")
    end

    test "returns error for missing column" do
      r = result(["a"], [[1]])
      assert {:error, _} = Statistics.detect_column_type(r, "missing")
    end
  end

  # --- Numeric edge cases ---

  describe "numeric statistics" do
    test "single value" do
      r = result(["v"], [[42]])
      {:ok, stats} = Statistics.compute(r, "v")

      assert stats.min == 42.0
      assert stats.max == 42.0
      assert stats.avg == 42.0
      assert stats.median == 42.0
      assert length(stats.histogram) == 1
    end

    test "even count median" do
      r = result(["v"], [[1], [2], [3], [4]])
      {:ok, stats} = Statistics.compute(r, "v")

      assert stats.median == 2.5
    end

    test "odd count median" do
      r = result(["v"], [[1], [3], [5]])
      {:ok, stats} = Statistics.compute(r, "v")

      assert stats.median == 3.0
    end

    test "handles Decimal values" do
      r = result(["v"], [[Decimal.new("1.5")], [Decimal.new("2.5")]])
      {:ok, stats} = Statistics.compute(r, "v")

      assert stats.type == :numeric
      assert stats.avg == 2.0
      assert stats.min == 1.5
      assert stats.max == 2.5
    end

    test "histogram distributes values into bins" do
      rows = for i <- 1..100, do: [i]
      r = result(["v"], rows)
      {:ok, stats} = Statistics.compute(r, "v")

      assert length(stats.histogram) == 10
      assert Enum.sum(Enum.map(stats.histogram, & &1.count)) == 100
    end

    test "all-nil numeric returns nil fields" do
      r = result(["v"], [[nil], [nil]])
      {:ok, stats} = Statistics.compute(r, "v")

      assert stats.type == :unknown
      assert stats.null_count == 2
    end
  end

  # --- String edge cases ---

  describe "string statistics" do
    test "empty strings" do
      r = result(["s"], [[""], ["a"]])
      {:ok, stats} = Statistics.compute(r, "s")

      assert stats.min_length == 0
      assert stats.max_length == 1
    end

    test "top_values limited to 10" do
      rows = for i <- 1..20, do: ["val_#{i}"]
      r = result(["s"], rows)
      {:ok, stats} = Statistics.compute(r, "s")

      assert length(stats.top_values) == 10
    end

    test "top_values sorted by frequency descending" do
      rows = [["a"], ["b"], ["a"], ["c"], ["b"], ["a"]]
      r = result(["s"], rows)
      {:ok, stats} = Statistics.compute(r, "s")

      [first, second, third] = stats.top_values
      assert first.value == "a" and first.count == 3
      assert second.value == "b" and second.count == 2
      assert third.value == "c" and third.count == 1
    end

    test "all-nil returns nil fields" do
      r = result(["s"], [[nil]])
      {:ok, stats} = Statistics.compute(r, "s")

      assert stats.type == :unknown
    end

    test "handles binaries that are not valid UTF-8" do
      invalid = <<194, 169, 153, 28, 40, 23, 204>>
      r = result(["s"], [[invalid], ["ok"], [invalid]])
      {:ok, stats} = Statistics.compute(r, "s")

      assert stats.type == :string
      assert stats.min_length == 2
      assert stats.max_length == 7
      assert %{value: ^invalid, count: 2} = hd(stats.top_values)
    end

    test "detects atoms as strings" do
      r = result(["s"], [[:active], [:inactive], [:active]])
      {:ok, stats} = Statistics.compute(r, "s")

      assert stats.type == :string
      assert stats.distinct_count == 2
    end
  end

  # --- Temporal edge cases ---

  describe "temporal statistics" do
    test "DateTime values" do
      rows = [
        [~U[2024-01-15 10:00:00Z]],
        [~U[2024-06-20 12:00:00Z]],
        [~U[2024-01-25 08:00:00Z]]
      ]

      r = result(["ts"], rows)
      {:ok, stats} = Statistics.compute(r, "ts")

      assert stats.earliest == ~U[2024-01-15 10:00:00Z]
      assert stats.latest == ~U[2024-06-20 12:00:00Z]
    end

    test "NaiveDateTime values" do
      rows = [[~N[2024-03-01 09:00:00]], [~N[2024-01-01 09:00:00]]]
      r = result(["ts"], rows)
      {:ok, stats} = Statistics.compute(r, "ts")

      assert stats.earliest == ~N[2024-01-01 09:00:00]
      assert stats.latest == ~N[2024-03-01 09:00:00]
    end

    test "distribution groups by year-month" do
      rows = [
        [~D[2024-01-01]],
        [~D[2024-01-15]],
        [~D[2024-02-10]],
        [~D[2024-02-20]],
        [~D[2024-02-28]]
      ]

      r = result(["d"], rows)
      {:ok, stats} = Statistics.compute(r, "d")

      assert [
               %{bucket: "2024-01", count: 2},
               %{bucket: "2024-02", count: 3}
             ] = stats.distribution
    end

    test "Time distribution groups by hour" do
      rows = [[~T[09:15:00]], [~T[09:45:00]], [~T[14:30:00]]]
      r = result(["t"], rows)
      {:ok, stats} = Statistics.compute(r, "t")

      assert stats.earliest == ~T[09:15:00]
      assert stats.latest == ~T[14:30:00]

      assert [
               %{bucket: "09:00", count: 2},
               %{bucket: "14:00", count: 1}
             ] = stats.distribution
    end

    test "all-nil returns nil fields" do
      r = result(["d"], [[nil]])
      {:ok, stats} = Statistics.compute(r, "d")

      assert stats.type == :unknown
    end
  end

  # --- Empty result ---

  describe "empty result" do
    test "handles zero rows" do
      r = result(["a", "b"], [])
      {:ok, stats} = Statistics.compute(r, "a")

      assert stats.type == :unknown
      assert stats.count == 0
      assert stats.null_count == 0
    end
  end
end
