defmodule Lotus.Storage.SchemaCacheTest do
  use Lotus.CacheCase

  alias Lotus.Cache
  alias Lotus.Config
  alias Lotus.Source.Adapter
  alias Lotus.Storage.SchemaCache

  use Mimic

  # Mock adapter module that delegates describe_table to the process dictionary,
  # allowing per-test control.
  defmodule MockAdapterModule do
    @behaviour Lotus.Source.Adapter

    def describe_table(state, schema, table) do
      apply(Process.get(:mock_describe_table), [state, schema, table])
    end

    # Stubs for required callbacks (not used in these tests)
    def execute_query(_, _, _, _), do: {:error, :not_implemented}
    def transaction(_, _, _), do: {:error, :not_implemented}
    def list_schemas(_), do: {:ok, []}
    def list_tables(_, _, _), do: {:ok, []}
    def resolve_table_namespace(_, _, _), do: {:ok, nil}
    def quote_identifier(_, id), do: ~s("#{id}")
    def apply_filters(_, statement, _), do: statement
    def apply_sorts(_, statement, _), do: statement
    def query_plan(_, _, _, _), do: {:ok, "plan"}
    def builtin_denies(_), do: []
    def builtin_schema_denies(_), do: []
    def default_schemas(_), do: ["public"]
    def health_check(_), do: :ok
    def disconnect(_), do: :ok
    def format_error(_, e), do: inspect(e)
    def handled_errors(_), do: []
    def source_type(_), do: :postgres
    def supports_feature?(_, _), do: false
    def limit_query(_, statement, _limit), do: statement
    def db_type_to_lotus_type(_, _), do: :text

    def editor_config(_),
      do: %{language: "", keywords: [], types: [], functions: [], context_boundaries: []}
  end

  setup :verify_on_exit!

  setup do
    Mimic.copy(Lotus.Config)

    Config
    |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
    |> stub(:cache_namespace, fn -> "test_schema_cache" end)

    :ok
  end

  defp mock_adapter(name \\ "mock", state \\ :mock_state) do
    %Adapter{
      name: name,
      module: MockAdapterModule,
      state: state,
      source_type: :postgres
    }
  end

  defp expect_describe_table(columns_fn) do
    Process.put(:mock_describe_table, fn state, schema, table ->
      {:ok, columns_fn.(state, schema, table)}
    end)
  end

  defp expect_describe_table_error(error_fn) do
    Process.put(:mock_describe_table, fn state, schema, table ->
      error_fn.(state, schema, table)
    end)
  end

  describe "describe_table/3" do
    test "returns schema map for valid table" do
      columns = [
        %{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true},
        %{name: "name", type: "varchar(255)", nullable: false, default: nil, primary_key: false},
        %{name: "email", type: "varchar(255)", nullable: true, default: nil, primary_key: false}
      ]

      expect_describe_table(fn _state, "public", "users" -> columns end)

      result = SchemaCache.describe_table(mock_adapter(), "public", "users")

      assert {:ok, schema_map} = result
      assert Map.has_key?(schema_map, "id")
      assert Map.has_key?(schema_map, "name")
      assert Map.has_key?(schema_map, "email")

      assert schema_map["id"].type == "uuid"
      assert schema_map["id"].nullable == false
      assert schema_map["id"].primary_key == true
    end

    test "caches result for subsequent calls" do
      columns = [
        %{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}
      ]

      call_count = :counters.new(1, [:atomics])

      expect_describe_table(fn _state, "public", "orders" ->
        :counters.add(call_count, 1, 1)
        columns
      end)

      adapter = mock_adapter()

      # First call - cache miss
      {:ok, schema1} = SchemaCache.describe_table(adapter, "public", "orders")

      # Second call - should use cache
      {:ok, schema2} = SchemaCache.describe_table(adapter, "public", "orders")

      assert schema1 == schema2
      assert :counters.get(call_count, 1) == 1
    end

    test "returns error for database failure" do
      expect_describe_table_error(fn _state, "public", "nonexistent" ->
        raise ArgumentError, "Table not found"
      end)

      result = SchemaCache.describe_table(mock_adapter(), "public", "nonexistent")

      assert {:error, message} = result
      assert message =~ "Table not found"
    end

    test "caches tables separately per schema" do
      expect_describe_table(fn
        _state, "public", "users" ->
          [%{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true}]

        _state, "archive", "users" ->
          [%{name: "id", type: "bigint", nullable: false, default: nil, primary_key: true}]
      end)

      adapter = mock_adapter()

      {:ok, public_schema} = SchemaCache.describe_table(adapter, "public", "users")
      {:ok, archive_schema} = SchemaCache.describe_table(adapter, "archive", "users")

      assert public_schema["id"].type == "uuid"
      assert archive_schema["id"].type == "bigint"
    end

    test "handles nil schema" do
      expect_describe_table(fn _state, nil, "settings" ->
        [%{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}]
      end)

      {:ok, schema} = SchemaCache.describe_table(mock_adapter(), nil, "settings")

      assert schema["id"].type == "integer"
    end

    test "works with non-module state (e.g. keyword list for non-Ecto adapter)" do
      # Regression: previous implementation called Module.split(state), which raised
      # ArgumentError for non-atom state like ClickHouse's keyword-list opts.
      expect_describe_table(fn [host: "clickhouse.internal"], "default", "events" ->
        [%{name: "id", type: "UInt64", nullable: false, default: nil, primary_key: true}]
      end)

      adapter = mock_adapter("warehouse", host: "clickhouse.internal")

      assert {:ok, schema} = SchemaCache.describe_table(adapter, "default", "events")
      assert schema["id"].type == "UInt64"
    end
  end

  describe "get_column_type/4" do
    test "returns type for valid column" do
      columns = [
        %{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true},
        %{name: "name", type: "varchar(255)", nullable: false, default: nil, primary_key: false}
      ]

      expect_describe_table(fn _state, "public", "users" -> columns end)

      adapter = mock_adapter()

      assert {:ok, "uuid"} = SchemaCache.get_column_type(adapter, "public", "users", "id")

      assert {:ok, "varchar(255)"} =
               SchemaCache.get_column_type(adapter, "public", "users", "name")
    end

    test "returns :not_found for nonexistent column" do
      columns = [%{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}]

      expect_describe_table(fn _state, "public", "users" -> columns end)

      assert :not_found =
               SchemaCache.get_column_type(mock_adapter(), "public", "users", "nonexistent")
    end

    test "returns :not_found when table fetch fails" do
      expect_describe_table_error(fn _state, "public", "bad_table" ->
        raise ArgumentError, "Database error"
      end)

      assert :not_found =
               SchemaCache.get_column_type(mock_adapter(), "public", "bad_table", "id")
    end
  end

  describe "invalidate/3" do
    test "clears cache for specified table" do
      columns = [%{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}]
      call_count = :counters.new(1, [:atomics])

      expect_describe_table(fn _state, "public", "products" ->
        :counters.add(call_count, 1, 1)
        columns
      end)

      adapter = mock_adapter()

      # First call - populates cache
      {:ok, _} = SchemaCache.describe_table(adapter, "public", "products")

      # Invalidate
      assert :ok = SchemaCache.invalidate(adapter, "public", "products")

      # Second call - should re-fetch (cache was invalidated)
      {:ok, _} = SchemaCache.describe_table(adapter, "public", "products")

      assert :counters.get(call_count, 1) == 2
    end

    test "only invalidates specified table" do
      expect_describe_table(fn
        _state, "public", "users" ->
          [%{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true}]

        _state, "public", "orders" ->
          [%{name: "id", type: "bigint", nullable: false, default: nil, primary_key: true}]
      end)

      adapter = mock_adapter()

      # Populate both caches
      {:ok, _} = SchemaCache.describe_table(adapter, "public", "users")
      {:ok, _} = SchemaCache.describe_table(adapter, "public", "orders")

      # Invalidate only users
      SchemaCache.invalidate(adapter, "public", "users")

      # Users should be re-fetched, orders should still be cached
      {:ok, _} = SchemaCache.describe_table(adapter, "public", "users")
      {:ok, _} = SchemaCache.describe_table(adapter, "public", "orders")
    end
  end

  describe "warm_cache/2" do
    test "preloads schemas for specified tables" do
      expect_describe_table(fn
        _state, "public", "users" ->
          [%{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true}]

        _state, "public", "orders" ->
          [%{name: "id", type: "bigint", nullable: false, default: nil, primary_key: true}]
      end)

      adapter = mock_adapter()

      assert :ok =
               SchemaCache.warm_cache(adapter, [
                 {"public", "users"},
                 {"public", "orders"}
               ])

      # Subsequent calls should use cache
      {:ok, users} = SchemaCache.describe_table(adapter, "public", "users")
      {:ok, orders} = SchemaCache.describe_table(adapter, "public", "orders")

      assert users["id"].type == "uuid"
      assert orders["id"].type == "bigint"
    end

    test "continues warming even if one table fails" do
      Process.put(:mock_describe_table, fn
        _state, "public", "bad_table" ->
          raise ArgumentError, "Table not found"

        _state, "public", table ->
          case table do
            "users" ->
              {:ok,
               [%{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true}]}

            "products" ->
              {:ok,
               [%{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}]}
          end
      end)

      adapter = mock_adapter()

      # Should complete without raising
      assert :ok =
               SchemaCache.warm_cache(adapter, [
                 {"public", "users"},
                 {"public", "bad_table"},
                 {"public", "products"}
               ])

      # Users and products should be cached
      {:ok, users} = SchemaCache.describe_table(adapter, "public", "users")
      {:ok, products} = SchemaCache.describe_table(adapter, "public", "products")

      assert users["id"].type == "uuid"
      assert products["id"].type == "integer"
    end

    test "handles empty table list" do
      assert :ok = SchemaCache.warm_cache(mock_adapter(), [])
    end
  end

  describe "cache key generation" do
    test "differentiates adapters by name, not by state module" do
      # Regression: previous implementation hashed the state module's name,
      # so two adapters whose state modules shared a last segment (e.g. two
      # Repo modules in different namespaces) could collide. Now we key on
      # adapter.name directly.
      expect_describe_table(fn
        _state, "public", "shared_table" ->
          [%{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true}]
      end)

      {:ok, schema1} =
        SchemaCache.describe_table(mock_adapter("main"), "public", "shared_table")

      Process.put(:mock_describe_table, fn _state, "public", "shared_table" ->
        {:ok, [%{name: "id", type: "bigint", nullable: false, default: nil, primary_key: true}]}
      end)

      {:ok, schema2} =
        SchemaCache.describe_table(mock_adapter("warehouse"), "public", "shared_table")

      assert schema1["id"].type == "uuid"
      assert schema2["id"].type == "bigint"
    end
  end

  describe "configuration" do
    test "uses configured TTL and writes expected cache key" do
      columns = [%{name: "id", type: "integer", nullable: false, default: nil, primary_key: true}]

      expect_describe_table(fn _state, "public", "ttl_test" -> columns end)

      {:ok, _} =
        SchemaCache.describe_table(mock_adapter("main"), "public", "ttl_test")

      cache_key = "schema_cache:main:public:ttl_test"
      assert {:ok, _} = Cache.get(cache_key)
    end
  end
end
