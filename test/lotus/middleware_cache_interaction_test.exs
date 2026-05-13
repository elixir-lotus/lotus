defmodule Lotus.MiddlewareCacheInteractionTest do
  @moduledoc """
  Tests that discovery middleware runs correctly when the schema cache is enabled.

  These tests lock in three contracts:
  1. Middleware runs on every call, not only on cache miss.
  2. Context-sensitive middleware sees each per-call context, even on cache hits.
  3. The adapter is still cached across calls (called only once).

  Coverage spans :list_tables, :list_schemas, :describe_table, and :list_relations.
  """

  use Lotus.CacheCase
  use Mimic

  alias Lotus.Middleware

  # --- Test middleware plugs ---

  defmodule CountingPlug do
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), :middleware_ran)
      {:cont, payload}
    end
  end

  defmodule ContextCapturePlug do
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:middleware_context, payload.context})
      {:cont, payload}
    end
  end

  # --- Fake adapter data ---

  @fake_adapter %Lotus.Source.Adapter{
    name: "test_source",
    module: Lotus.Source.Adapters.Ecto,
    state: nil,
    source_type: :postgres
  }

  @fake_schemas ["public", "reporting"]
  @fake_tables [{"public", "users"}, {"public", "orders"}]
  @fake_columns [
    %{name: "id", type: "uuid", nullable: false, default: nil, primary_key: true},
    %{name: "name", type: "varchar(255)", nullable: false, default: nil, primary_key: false}
  ]

  setup :verify_on_exit!

  setup do
    Mimic.copy(Lotus.Config)
    Mimic.copy(Lotus.Source)
    Mimic.copy(Lotus.Source.Adapter)
    Mimic.copy(Lotus.Visibility)

    # Enable the cache with a stable namespace per test
    namespace = "test_mw_cache_#{System.unique_integer([:positive])}"

    Lotus.Config
    |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
    |> stub(:cache_namespace, fn -> namespace end)
    |> stub(:cache_config, fn -> %{default_ttl_ms: :timer.seconds(60)} end)
    |> stub(:default_cache_profile, fn -> :schema end)
    |> stub(:cache_profile_settings, fn _profile -> [ttl_ms: :timer.seconds(60)] end)
    |> stub(:cache_key_builder, fn -> Lotus.Cache.KeyBuilder.Default end)

    # Resolve source name to our fake adapter
    Lotus.Source
    |> stub(:resolve!, fn _repo, _fallback -> @fake_adapter end)

    # Default schemas
    Lotus.Source.Adapter
    |> stub(:default_schemas, fn _adapter -> ["public"] end)

    # Visibility: allow everything through
    Lotus.Visibility
    |> stub(:filter_schemas, fn schemas, _source, _scope -> schemas end)
    |> stub(:validate_schemas, fn _schemas, _source, _scope -> :ok end)
    |> stub(:allowed_relation?, fn _source, _rel, _scope -> true end)
    |> stub(:column_policy_for, fn _source, _rels, _col, _scope -> nil end)

    # Reset middleware between tests
    on_exit(fn ->
      try do
        :persistent_term.erase({Lotus.Middleware, :compiled})
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  # ─────────────────────────────────────────────────
  # list_tables
  # ─────────────────────────────────────────────────

  describe "list_tables with cache" do
    test "middleware runs on every call, not only on cache miss" do
      Lotus.Source.Adapter
      |> stub(:list_tables, fn _adapter, _schemas, _opts -> {:ok, @fake_tables} end)

      Middleware.compile(%{after_list_tables: [{CountingPlug, []}]})

      {:ok, _} = Lotus.list_tables("test_source")
      {:ok, _} = Lotus.list_tables("test_source")
      {:ok, _} = Lotus.list_tables("test_source")

      assert_received :middleware_ran
      assert_received :middleware_ran
      assert_received :middleware_ran
    end

    test "context-sensitive middleware sees each per-call context, even on cache hits" do
      Lotus.Source.Adapter
      |> stub(:list_tables, fn _adapter, _schemas, _opts -> {:ok, @fake_tables} end)

      Middleware.compile(%{after_list_tables: [{ContextCapturePlug, []}]})

      {:ok, _} = Lotus.list_tables("test_source", context: %{tenant: "acme"})
      {:ok, _} = Lotus.list_tables("test_source", context: %{tenant: "globex"})

      assert_received {:middleware_context, %{tenant: "acme"}}
      assert_received {:middleware_context, %{tenant: "globex"}}
    end

    test "adapter is only called once across multiple identical calls" do
      test_pid = self()

      Lotus.Source.Adapter
      |> stub(:list_tables, fn _adapter, _schemas, _opts ->
        send(test_pid, :adapter_called)
        {:ok, @fake_tables}
      end)

      Middleware.compile(%{})

      {:ok, tables1} = Lotus.list_tables("test_source")
      {:ok, tables2} = Lotus.list_tables("test_source")
      {:ok, tables3} = Lotus.list_tables("test_source")

      assert tables1 == @fake_tables
      assert tables2 == @fake_tables
      assert tables3 == @fake_tables

      # Adapter called exactly once — subsequent calls served from cache
      assert_received :adapter_called
      refute_received :adapter_called
    end
  end

  # ─────────────────────────────────────────────────
  # list_schemas
  # ─────────────────────────────────────────────────

  describe "list_schemas with cache" do
    test "middleware runs on every call, not only on cache miss" do
      Lotus.Source.Adapter
      |> stub(:list_schemas, fn _adapter -> {:ok, @fake_schemas} end)

      Middleware.compile(%{after_list_schemas: [{CountingPlug, []}]})

      {:ok, _} = Lotus.list_schemas("test_source")
      {:ok, _} = Lotus.list_schemas("test_source")
      {:ok, _} = Lotus.list_schemas("test_source")

      assert_received :middleware_ran
      assert_received :middleware_ran
      assert_received :middleware_ran
    end

    test "context-sensitive middleware sees each per-call context, even on cache hits" do
      Lotus.Source.Adapter
      |> stub(:list_schemas, fn _adapter -> {:ok, @fake_schemas} end)

      Middleware.compile(%{after_list_schemas: [{ContextCapturePlug, []}]})

      {:ok, _} = Lotus.list_schemas("test_source", context: %{tenant: "acme"})
      {:ok, _} = Lotus.list_schemas("test_source", context: %{tenant: "globex"})

      assert_received {:middleware_context, %{tenant: "acme"}}
      assert_received {:middleware_context, %{tenant: "globex"}}
    end

    test "adapter is only called once across multiple identical calls" do
      test_pid = self()

      Lotus.Source.Adapter
      |> stub(:list_schemas, fn _adapter ->
        send(test_pid, :adapter_called)
        {:ok, @fake_schemas}
      end)

      Middleware.compile(%{})

      {:ok, schemas1} = Lotus.list_schemas("test_source")
      {:ok, schemas2} = Lotus.list_schemas("test_source")
      {:ok, schemas3} = Lotus.list_schemas("test_source")

      assert schemas1 == @fake_schemas
      assert schemas2 == @fake_schemas
      assert schemas3 == @fake_schemas

      assert_received :adapter_called
      refute_received :adapter_called
    end
  end

  # ─────────────────────────────────────────────────
  # describe_table
  # ─────────────────────────────────────────────────

  describe "describe_table with cache" do
    test "middleware runs on every call, not only on cache miss" do
      Lotus.Source.Adapter
      |> stub(:resolve_table_namespace, fn _a, _t, _s -> {:ok, "public"} end)
      |> stub(:describe_table, fn _a, "public", "users" -> {:ok, @fake_columns} end)

      Middleware.compile(%{after_describe_table: [{CountingPlug, []}]})

      {:ok, _} = Lotus.describe_table("test_source", "users")
      {:ok, _} = Lotus.describe_table("test_source", "users")
      {:ok, _} = Lotus.describe_table("test_source", "users")

      assert_received :middleware_ran
      assert_received :middleware_ran
      assert_received :middleware_ran
    end

    test "context-sensitive middleware sees each per-call context, even on cache hits" do
      Lotus.Source.Adapter
      |> stub(:resolve_table_namespace, fn _a, _t, _s -> {:ok, "public"} end)
      |> stub(:describe_table, fn _a, "public", "users" -> {:ok, @fake_columns} end)

      Middleware.compile(%{after_describe_table: [{ContextCapturePlug, []}]})

      {:ok, _} = Lotus.describe_table("test_source", "users", context: %{tenant: "acme"})
      {:ok, _} = Lotus.describe_table("test_source", "users", context: %{tenant: "globex"})

      assert_received {:middleware_context, %{tenant: "acme"}}
      assert_received {:middleware_context, %{tenant: "globex"}}
    end

    test "adapter is only called once across multiple identical calls" do
      test_pid = self()

      Lotus.Source.Adapter
      |> stub(:resolve_table_namespace, fn _a, _t, _s ->
        send(test_pid, :resolve_called)
        {:ok, "public"}
      end)
      |> stub(:describe_table, fn _a, "public", "users" ->
        send(test_pid, :adapter_called)
        {:ok, @fake_columns}
      end)

      Middleware.compile(%{})

      {:ok, cols1} = Lotus.describe_table("test_source", "users")
      {:ok, cols2} = Lotus.describe_table("test_source", "users")
      {:ok, cols3} = Lotus.describe_table("test_source", "users")

      assert cols1 == cols2
      assert cols2 == cols3

      # Both resolve and describe_table cached after first call
      assert_received :resolve_called
      refute_received :resolve_called
      assert_received :adapter_called
      refute_received :adapter_called
    end
  end

  # ─────────────────────────────────────────────────
  # list_relations
  # ─────────────────────────────────────────────────

  describe "list_relations with cache" do
    test "middleware runs on every call, not only on cache miss" do
      Lotus.Source.Adapter
      |> stub(:list_tables, fn _adapter, _schemas, _opts -> {:ok, @fake_tables} end)

      Middleware.compile(%{after_list_relations: [{CountingPlug, []}]})

      {:ok, _} = Lotus.list_relations("test_source")
      {:ok, _} = Lotus.list_relations("test_source")
      {:ok, _} = Lotus.list_relations("test_source")

      assert_received :middleware_ran
      assert_received :middleware_ran
      assert_received :middleware_ran
    end

    test "context-sensitive middleware sees each per-call context, even on cache hits" do
      Lotus.Source.Adapter
      |> stub(:list_tables, fn _adapter, _schemas, _opts -> {:ok, @fake_tables} end)

      Middleware.compile(%{after_list_relations: [{ContextCapturePlug, []}]})

      {:ok, _} = Lotus.list_relations("test_source", context: %{tenant: "acme"})
      {:ok, _} = Lotus.list_relations("test_source", context: %{tenant: "globex"})

      assert_received {:middleware_context, %{tenant: "acme"}}
      assert_received {:middleware_context, %{tenant: "globex"}}
    end

    test "adapter is only called once across multiple identical calls" do
      test_pid = self()

      Lotus.Source.Adapter
      |> stub(:list_tables, fn _adapter, _schemas, _opts ->
        send(test_pid, :adapter_called)
        {:ok, @fake_tables}
      end)

      Middleware.compile(%{})

      {:ok, rels1} = Lotus.list_relations("test_source")
      {:ok, rels2} = Lotus.list_relations("test_source")
      {:ok, rels3} = Lotus.list_relations("test_source")

      assert rels1 == @fake_tables
      assert rels2 == @fake_tables
      assert rels3 == @fake_tables

      assert_received :adapter_called
      refute_received :adapter_called
    end
  end

  # ─────────────────────────────────────────────────
  # after_discover unified event
  # ─────────────────────────────────────────────────

  describe "after_discover unified event with cache" do
    test "fires on every call even when cached (list_tables)" do
      Lotus.Source.Adapter
      |> stub(:list_tables, fn _a, _s, _o -> {:ok, @fake_tables} end)

      Middleware.compile(%{after_discover: [{CountingPlug, []}]})

      {:ok, _} = Lotus.list_tables("test_source")
      {:ok, _} = Lotus.list_tables("test_source")

      assert_received :middleware_ran
      assert_received :middleware_ran
    end

    test "context flows through after_discover on cache hits" do
      Lotus.Source.Adapter
      |> stub(:list_tables, fn _a, _s, _o -> {:ok, @fake_tables} end)

      Middleware.compile(%{after_discover: [{ContextCapturePlug, []}]})

      {:ok, _} = Lotus.list_tables("test_source", context: %{user: "alice"})
      {:ok, _} = Lotus.list_tables("test_source", context: %{user: "bob"})

      assert_received {:middleware_context, %{user: "alice"}}
      assert_received {:middleware_context, %{user: "bob"}}
    end
  end
end
