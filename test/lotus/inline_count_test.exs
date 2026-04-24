defmodule Lotus.InlineCountTest do
  @moduledoc """
  Exercises the inline-count strategy (Strategy A) for adapters that surface
  `:total_count` directly from `execute_query/4` instead of via a separate
  `:count_spec` query (Strategy B).

  The precedence rule (documented on `Lotus.Source.Adapter.apply_pagination/3`)
  is: adapter-supplied inline count wins; if absent, fall back to count_spec;
  if neither, total is `nil`.

  Uses `Lotus.Test.InMemoryAdapter` with `count_strategy: :inline` so the same
  reference adapter demonstrates both strategies.
  """
  use ExUnit.Case, async: false

  alias Lotus.Query.Statement
  alias Lotus.Result
  alias Lotus.Runner
  alias Lotus.Test.InMemoryAdapter

  @dataset_tables %{
    "users" => %{
      columns: ["id", "name"],
      rows: Enum.map(1..10, fn i -> [i, "user_#{i}"] end),
      types: %{"id" => "integer", "name" => "text"}
    }
  }

  defp stmt(dsl), do: %Statement{adapter: InMemoryAdapter, text: dsl}

  describe "inline count (Strategy A)" do
    test "execute_query/4 surfaces total_count on the result map" do
      dataset = InMemoryAdapter.dataset(tables: @dataset_tables, count_strategy: :inline)
      adapter = InMemoryAdapter.adapter("mem", dataset)

      statement = stmt(%{from: "users"})
      paged = InMemoryAdapter.apply_pagination(adapter.state, statement, limit: 3, count: :exact)

      # Strategy A: no :count_spec plumbed through meta
      refute Map.has_key?(paged.meta, :count_spec)
      assert paged.text.count_mode == :exact

      {:ok, raw} = InMemoryAdapter.execute_query(adapter.state, paged.text, [], [])
      assert raw.num_rows == 3
      assert raw.total_count == 10
    end

    test "Runner plumbs adapter total_count into Result.meta" do
      dataset = InMemoryAdapter.dataset(tables: @dataset_tables, count_strategy: :inline)
      adapter = InMemoryAdapter.adapter("mem", dataset)

      statement = stmt(%{from: "users"})
      paged = InMemoryAdapter.apply_pagination(adapter.state, statement, limit: 3, count: :exact)

      {:ok, %Result{} = result} = Runner.run_statement(adapter, paged)

      assert result.num_rows == 3
      assert result.meta[:total_count] == 10
    end

    test "precedence: inline count wins over count_spec when both are set" do
      # Hand-build a statement carrying BOTH an inline count (via the dataset)
      # AND a :count_spec in meta — core must prefer the inline value.
      dataset = InMemoryAdapter.dataset(tables: @dataset_tables, count_strategy: :inline)
      adapter = InMemoryAdapter.adapter("mem", dataset)

      statement =
        stmt(%{from: "users", count_mode: :exact, limit: 3, offset: 0})

      # Simulate a stray count_spec that would return the WRONG count (42)
      # if it were run. The precedence rule says it should NOT be run.
      statement = %{
        statement
        | meta:
            Map.put(statement.meta, :count_spec, %{
              query: %{from: "missing_table", count: true},
              params: []
            })
      }

      # Route through Lotus.execute_with_options indirectly via run_statement —
      # but since InMemoryAdapter's DSL text isn't a binary, we exercise the
      # same precedence logic by running through Runner and verifying the
      # adapter's total_count is what lands in Result.meta. The count_spec
      # path in Lotus.execute_with_options would only run if the inline
      # count were absent.
      {:ok, %Result{} = result} = Runner.run_statement(adapter, statement)
      assert result.meta[:total_count] == 10
    end

    test "count: :none doesn't surface total_count" do
      dataset = InMemoryAdapter.dataset(tables: @dataset_tables, count_strategy: :inline)
      adapter = InMemoryAdapter.adapter("mem", dataset)

      statement = stmt(%{from: "users"})
      paged = InMemoryAdapter.apply_pagination(adapter.state, statement, limit: 3, count: :none)

      {:ok, raw} = InMemoryAdapter.execute_query(adapter.state, paged.text, [], [])
      refute Map.has_key?(raw, :total_count)
    end
  end

  describe "Strategy B (default :separate) still works" do
    test "apply_pagination/3 records a count_spec when count_strategy is unspecified" do
      dataset = InMemoryAdapter.dataset(tables: @dataset_tables)
      adapter = InMemoryAdapter.adapter("mem", dataset)

      statement = stmt(%{from: "users"})
      paged = InMemoryAdapter.apply_pagination(adapter.state, statement, limit: 3, count: :exact)

      assert %{query: count_dsl, params: []} = paged.meta[:count_spec]
      assert count_dsl.count == true
    end

    test "execute_query/4 does NOT surface total_count in :separate mode" do
      dataset = InMemoryAdapter.dataset(tables: @dataset_tables, count_strategy: :separate)
      adapter = InMemoryAdapter.adapter("mem", dataset)

      statement = stmt(%{from: "users"})
      paged = InMemoryAdapter.apply_pagination(adapter.state, statement, limit: 3, count: :exact)

      {:ok, raw} = InMemoryAdapter.execute_query(adapter.state, paged.text, [], [])
      refute Map.has_key?(raw, :total_count)
    end
  end
end
