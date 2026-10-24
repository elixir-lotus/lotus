defmodule Lotus.ResultCostTest do
  @moduledoc """
  An adapter that reports what a statement cost the engine (`:cost` in the
  `execute_query/4` result) has it in the result's `meta.cost` and in the
  measurements of `[:lotus, :query, :stop]`.
  """
  use ExUnit.Case, async: false

  alias Lotus.Query.Statement
  alias Lotus.Result
  alias Lotus.Runner
  alias Lotus.Test.InMemoryAdapter

  @tables %{
    "users" => %{
      columns: ["id"],
      rows: [[1], [2]],
      types: %{"id" => "integer"}
    }
  }

  defp run(cost) do
    adapter = InMemoryAdapter.adapter("mem", InMemoryAdapter.dataset(tables: @tables, cost: cost))
    Runner.run_statement(adapter, %Statement{adapter: InMemoryAdapter, body: %{from: "users"}})
  end

  defp capture_query_stop do
    ref = make_ref()
    pid = self()

    :telemetry.attach(
      "#{inspect(ref)}",
      [:lotus, :query, :stop],
      fn _event, measurements, _metadata, _ -> send(pid, {:query_stop, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)
  end

  test "the cost is in the result's meta and the query stop measurements" do
    capture_query_stop()

    assert {:ok, %Result{meta: %{cost: cost}}} =
             run(%{
               bytes_scanned: 1_024,
               bytes_billed: 10_485_760,
               rows_scanned: 2,
               credits: 0.25
             })

    assert cost == %{
             bytes_scanned: 1_024,
             bytes_billed: 10_485_760,
             rows_scanned: 2,
             credits: 0.25
           }

    assert_received {:query_stop, measurements}
    assert %{bytes_scanned: 1_024, bytes_billed: 10_485_760, rows_scanned: 2} = measurements
    assert measurements.credits == 0.25
    assert is_integer(measurements.duration)
    assert measurements.row_count == 2
  end

  test "unknown keys and bad values are dropped" do
    assert {:ok, %Result{meta: %{cost: %{bytes_scanned: 10}}}} =
             run(%{bytes_scanned: 10, rows_scanned: -1, credits: "a lot", slots: 4})
  end

  test "no cost, or nothing usable, leaves no cost" do
    capture_query_stop()

    assert {:ok, %Result{meta: meta}} = run(nil)
    refute Map.has_key?(meta, :cost)

    assert_received {:query_stop, measurements}
    assert Map.keys(measurements) |> Enum.sort() == [:duration, :row_count]

    assert {:ok, %Result{meta: meta}} = run(%{rows_scanned: 1.5})
    refute Map.has_key?(meta, :cost)
  end
end
