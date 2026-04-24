defmodule Lotus.Integration.NonSql.InMemoryEndToEndTest do
  @moduledoc """
  End-to-end integration test exercising a non-SQL adapter registered via
  `:data_sources` + `:source_adapters` — from resolver lookup through
  introspection, Runner execution, and cache invalidation.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Lotus.Cache
  alias Lotus.Config
  alias Lotus.Query.Filter
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source
  alias Lotus.Source.Adapter
  alias Lotus.Test.InMemoryAdapter

  @source_name "mem"

  @dataset_tables %{
    "users" => %{
      columns: ["id", "name", "status"],
      rows: [
        [1, "Alice", "active"],
        [2, "Bob", "inactive"]
      ]
    }
  }

  setup do
    prev_sources = Application.get_env(:lotus, :data_sources)
    prev_default = Application.get_env(:lotus, :default_source)
    prev_adapters = Application.get_env(:lotus, :source_adapters)

    dataset = InMemoryAdapter.dataset(tables: @dataset_tables)

    Application.put_env(:lotus, :data_sources, %{
      @source_name => dataset,
      "postgres" => Lotus.Test.Repo
    })

    Application.put_env(:lotus, :source_adapters, [InMemoryAdapter])
    Application.put_env(:lotus, :default_source, "postgres")

    Config.reload!()

    on_exit(fn ->
      restore_env(:data_sources, prev_sources)
      restore_env(:default_source, prev_default)
      restore_env(:source_adapters, prev_adapters)
      Config.reload!()
    end)

    %{dataset: dataset}
  end

  defp restore_env(key, nil), do: Application.delete_env(:lotus, key)
  defp restore_env(key, value), do: Application.put_env(:lotus, key, value)

  describe "resolver → introspection" do
    test "Source.get_source!/1 resolves the registered adapter" do
      %Adapter{} = adapter = Source.get_source!(@source_name)
      assert adapter.module == InMemoryAdapter
      assert adapter.source_type == :in_memory
      assert Source.query_language(adapter) == "lotus:in_memory"
    end

    test "Lotus.list_tables/1 lists the dataset's tables" do
      # When all relations have a nil schema, Lotus flattens the shape to
      # `[table_name, ...]`. See `Lotus.Schema.list_tables/2`.
      assert {:ok, ["users"]} = Lotus.list_tables(@source_name)
    end

    test "Lotus.describe_table/2 returns column definitions" do
      assert {:ok, cols} = Lotus.describe_table(@source_name, "users")
      assert Enum.map(cols, & &1.name) == ["id", "name", "status"]
    end
  end

  describe "Runner — executing a DSL statement" do
    test "runs a filtered query end-to-end" do
      adapter = Source.get_source!(@source_name)

      statement = %Statement{
        adapter: adapter.module,
        text: %{from: "users"}
      }

      statement = Adapter.apply_filters(adapter, statement, [Filter.new("status", :eq, "active")])

      assert {:ok, %{rows: [[1, "Alice", "active"]]}} =
               Runner.run_statement(adapter, statement)
    end
  end

  describe "cache invalidation via source tag" do
    setup do
      Mimic.copy(Config)

      Config
      |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
      |> stub(:cache_namespace, fn -> "non_sql_integration_test" end)

      for table <- [:lotus_cache, :lotus_cache_tags] do
        if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
      end

      on_exit(fn ->
        for table <- [:lotus_cache, :lotus_cache_tags] do
          if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
        end
      end)

      :ok
    end

    test "Cache.invalidate_tags/1 clears entries tagged `source:<name>`" do
      # Seed a cached entry tagged "source:mem" — the same tag Lotus attaches
      # to every result-cache entry (`Lotus.build_cache_tags/3`). We don't
      # route through Lotus.run_statement/2 because the default result-key
      # builder expects a binary statement text; the in-memory adapter's
      # DSL-map text is a deliberate non-SQL payload.
      key = "test:hit"
      assert :ok = Cache.put(key, "cached", 60_000, tags: ["source:#{@source_name}"])
      assert {:ok, "cached"} = Cache.get(key)

      assert :ok = Cache.invalidate_tags(["source:#{@source_name}"])
      assert Cache.get(key) == :miss
    end
  end
end
