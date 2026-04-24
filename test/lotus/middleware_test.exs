defmodule Lotus.MiddlewareTest do
  use Lotus.Case, async: false

  alias Lotus.{Middleware, Result, Runner}
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  import Lotus.Fixtures

  @pg_adapter EctoAdapter.wrap("postgres", Lotus.Test.Repo)

  # --- Middleware modules for testing ---

  defmodule PassthroughPlug do
    def init(opts), do: opts

    def call(payload, _opts) do
      {:cont, payload}
    end
  end

  defmodule HaltPlug do
    def init(opts), do: opts

    def call(_payload, opts) do
      {:halt, Keyword.get(opts, :reason, "halted by middleware")}
    end
  end

  defmodule ContextCapturePlug do
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:middleware_context, payload.context})
      {:cont, payload}
    end
  end

  defmodule InitTransformPlug do
    def init(opts) do
      Keyword.put(opts, :compiled, true)
    end

    def call(payload, opts) do
      send(self(), {:init_opts, opts})
      {:cont, payload}
    end
  end

  defmodule TableFilterPlug do
    def init(opts), do: opts

    def call(%{tables: tables} = payload, opts) do
      blocked = Keyword.get(opts, :block_tables, [])
      filtered = Enum.reject(tables, fn t -> table_name(t) in blocked end)
      {:cont, %{payload | tables: filtered}}
    end

    defp table_name({_schema, name}), do: name
    defp table_name(name) when is_binary(name), do: name
  end

  defmodule KindDispatchPlug do
    def init(opts), do: opts

    def call(%{kind: kind, result: result} = payload, _opts) do
      send(self(), {:dispatched, kind, result})
      {:cont, payload}
    end
  end

  defmodule CountingPlug do
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), :middleware_ran)
      {:cont, payload}
    end
  end

  defmodule OrderingProbePlug do
    def init(opts), do: opts

    def call(payload, opts) do
      send(self(), {:ordering_probe, Keyword.fetch!(opts, :tag)})
      {:cont, payload}
    end
  end

  defmodule DiscoverResultMutatorPlug do
    def init(opts), do: opts

    def call(%{kind: :list_tables, result: [_ | rest]} = payload, _opts) do
      {:cont, %{payload | result: rest}}
    end

    def call(payload, _opts) do
      {:cont, payload}
    end
  end

  defmodule RaisingPlug do
    def init(opts), do: opts

    def call(_payload, opts) do
      raise Keyword.fetch!(opts, :message)
    end
  end

  defmodule ScopeCapturePlug do
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:middleware_scope, payload[:scope]})
      {:cont, payload}
    end
  end

  defp reset_middleware do
    :persistent_term.erase({Lotus.Middleware, :compiled})
    :ok
  end

  setup do
    on_exit(fn -> reset_middleware() end)

    setup_test_data()
  end

  describe "compile/1" do
    test "compiles middleware and stores in persistent_term" do
      Middleware.compile(%{
        before_query: [{InitTransformPlug, [key: :value]}]
      })

      entries = Middleware.compiled_pipeline(:before_query)
      assert [{InitTransformPlug, compiled_opts}] = entries
      assert compiled_opts[:compiled] == true
      assert compiled_opts[:key] == :value
    end

    test "handles empty middleware config" do
      Middleware.compile(%{})

      assert Middleware.compiled_pipeline(:before_query) == []
      assert Middleware.compiled_pipeline(:after_query) == []
      assert Middleware.compiled_pipeline(:after_list_tables) == []
    end

    test "empty map returns :ok without error" do
      assert :ok = Middleware.compile(%{})
    end
  end

  describe "run/2" do
    test "returns {:cont, payload} when no middleware configured" do
      payload = %{sql: "SELECT 1", context: nil}

      assert {:cont, ^payload} = Middleware.run(:before_query, payload)
    end

    test "passes payload through passthrough middleware" do
      Middleware.compile(%{
        before_query: [{PassthroughPlug, []}]
      })

      payload = %{sql: "SELECT 1", context: nil}

      assert {:cont, ^payload} = Middleware.run(:before_query, payload)
    end

    test "halts pipeline when middleware returns :halt" do
      Middleware.compile(%{
        before_query: [{HaltPlug, [reason: "access denied"]}]
      })

      payload = %{sql: "SELECT 1", context: nil}

      assert {:halt, "access denied"} = Middleware.run(:before_query, payload)
    end

    test "stops at first halting middleware" do
      Middleware.compile(%{
        before_query: [
          {HaltPlug, [reason: "stopped"]},
          {ContextCapturePlug, []}
        ]
      })

      Middleware.run(:before_query, %{context: :should_not_reach})

      refute_received {:middleware_context, _}
    end

    test "chains multiple middleware in order" do
      Middleware.compile(%{
        before_query: [
          {PassthroughPlug, []},
          {ContextCapturePlug, []}
        ]
      })

      Middleware.run(:before_query, %{context: :test_user})

      assert_received {:middleware_context, :test_user}
    end

    test "raised exception returns {:halt, exception}" do
      Middleware.compile(%{
        before_query: [{RaisingPlug, [message: "pipeline boom"]}]
      })

      assert {:halt, %RuntimeError{message: "pipeline boom"}} =
               Middleware.run(:before_query, %{sql: "SELECT 1", context: nil})
    end
  end

  describe "before_query integration" do
    test "passthrough middleware does not affect query execution" do
      Middleware.compile(%{
        before_query: [{PassthroughPlug, []}]
      })

      assert {:ok, %Result{}} = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "halting middleware prevents query execution" do
      Middleware.compile(%{
        before_query: [{HaltPlug, [reason: "not allowed"]}]
      })

      assert {:error, "not allowed"} =
               Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "context is passed to before_query middleware" do
      Middleware.compile(%{
        before_query: [{ContextCapturePlug, []}]
      })

      Runner.run_statement(@pg_adapter, Statement.new("SELECT 1", []),
        context: %{user: "alice@example.com"}
      )

      assert_received {:middleware_context, %{user: "alice@example.com"}}
    end

    test "nil context when not provided" do
      Middleware.compile(%{
        before_query: [{ContextCapturePlug, []}]
      })

      Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))

      assert_received {:middleware_context, nil}
    end

    test "halting before_query does not run after_query middleware" do
      Middleware.compile(%{
        before_query: [{HaltPlug, [reason: "denied"]}],
        after_query: [{CountingPlug, []}]
      })

      assert {:error, "denied"} = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))

      refute_received :middleware_ran
    end
  end

  describe "after_query integration" do
    test "passthrough middleware returns result unchanged" do
      Middleware.compile(%{
        after_query: [{PassthroughPlug, []}]
      })

      assert {:ok, %Result{rows: [[1]]}} =
               Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "halting middleware in after_query returns error" do
      Middleware.compile(%{
        after_query: [{HaltPlug, [reason: "post-query denied"]}]
      })

      assert {:error, "post-query denied"} =
               Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "context flows to after_query middleware" do
      Middleware.compile(%{
        after_query: [{ContextCapturePlug, []}]
      })

      Runner.run_statement(@pg_adapter, Statement.new("SELECT 1", []), context: %{role: :admin})

      assert_received {:middleware_context, %{role: :admin}}
    end
  end

  describe "after_list_tables integration" do
    test "passthrough middleware does not affect list_tables" do
      Middleware.compile(%{
        after_list_tables: [{PassthroughPlug, []}]
      })

      assert {:ok, tables} = Lotus.list_tables("postgres")
      refute tables == []
    end

    test "halting middleware blocks table discovery" do
      Middleware.compile(%{
        after_list_tables: [{HaltPlug, [reason: "discovery denied"]}]
      })

      assert {:error, "discovery denied"} = Lotus.list_tables("postgres")
    end

    test "middleware can filter discovery results" do
      Middleware.compile(%{
        after_list_tables: [{TableFilterPlug, [block_tables: ["users"]]}]
      })

      assert {:ok, tables} = Lotus.list_tables("postgres")

      table_names = Enum.map(tables, fn {_s, t} -> t end)
      refute "users" in table_names
    end

    test "context flows to after_list_tables middleware" do
      Middleware.compile(%{
        after_list_tables: [{ContextCapturePlug, []}]
      })

      Lotus.list_tables("postgres", context: %{tenant: "acme"})

      assert_received {:middleware_context, %{tenant: "acme"}}
    end
  end

  describe "after_list_schemas integration" do
    test "halting middleware blocks schema discovery" do
      Middleware.compile(%{
        after_list_schemas: [{HaltPlug, [reason: "schema denied"]}]
      })

      assert {:error, "schema denied"} = Lotus.list_schemas("postgres")
    end

    test "context flows to after_list_schemas middleware" do
      Middleware.compile(%{
        after_list_schemas: [{ContextCapturePlug, []}]
      })

      Lotus.list_schemas("postgres", context: %{user: "eve@example.com"})

      assert_received {:middleware_context, %{user: "eve@example.com"}}
    end
  end

  describe "context passing from public API" do
    test "run_query passes context through" do
      Middleware.compile(%{
        before_query: [{ContextCapturePlug, []}]
      })

      query = query_fixture(%{name: "ctx_test", statement: "SELECT 1"})
      Lotus.run_query(query, context: %{user: "bob@example.com"})

      assert_received {:middleware_context, %{user: "bob@example.com"}}
    end

    test "run_statement passes context through" do
      Middleware.compile(%{
        before_query: [{ContextCapturePlug, []}]
      })

      Lotus.run_statement("SELECT 1", [], context: %{user: "carol@example.com"})

      assert_received {:middleware_context, %{user: "carol@example.com"}}
    end

    @tag :sqlite
    test "describe_table passes context through" do
      Middleware.compile(%{
        after_describe_table: [{ContextCapturePlug, []}]
      })

      assert {:ok, _} =
               Lotus.describe_table("sqlite", "products", context: %{user: "dave@example.com"})

      assert_received {:middleware_context, %{user: "dave@example.com"}}
    end

    test "list_schemas passes context through" do
      Middleware.compile(%{
        after_list_schemas: [{ContextCapturePlug, []}]
      })

      Lotus.list_schemas("postgres", context: %{user: "eve@example.com"})

      assert_received {:middleware_context, %{user: "eve@example.com"}}
    end
  end

  describe "after_discover integration" do
    test "fires for :list_schemas with kind and result in payload" do
      Middleware.compile(%{
        after_discover: [{KindDispatchPlug, []}]
      })

      assert {:ok, schemas} = Lotus.list_schemas("postgres")
      assert_received {:dispatched, :list_schemas, ^schemas}
    end

    test "fires for :list_tables with kind and result in payload" do
      Middleware.compile(%{
        after_discover: [{KindDispatchPlug, []}]
      })

      assert {:ok, tables} = Lotus.list_tables("postgres")
      assert_received {:dispatched, :list_tables, ^tables}
    end

    @tag :sqlite
    test "fires for :describe_table with kind and result in payload" do
      Middleware.compile(%{
        after_discover: [{KindDispatchPlug, []}]
      })

      assert {:ok, columns} = Lotus.describe_table("sqlite", "products")
      assert_received {:dispatched, :describe_table, ^columns}
    end

    test "fires for :list_relations with kind and result in payload" do
      Middleware.compile(%{
        after_discover: [{KindDispatchPlug, []}]
      })

      assert {:ok, relations} = Lotus.list_relations("postgres")
      assert_received {:dispatched, :list_relations, ^relations}
    end

    test "context flows through to :after_discover" do
      Middleware.compile(%{
        after_discover: [{ContextCapturePlug, []}]
      })

      Lotus.list_tables("postgres", context: %{user: "zoe@example.com"})

      assert_received {:middleware_context, %{user: "zoe@example.com"}}
    end

    test "halt propagates as {:error, reason}" do
      Middleware.compile(%{
        after_discover: [{HaltPlug, [reason: "denied by discovery policy"]}]
      })

      assert {:error, "denied by discovery policy"} = Lotus.list_tables("postgres")
    end

    test "middleware can transform :result" do
      Middleware.compile(%{})
      {:ok, full_tables} = Lotus.list_tables("postgres")

      Middleware.compile(%{
        after_discover: [{DiscoverResultMutatorPlug, []}]
      })

      assert {:ok, mutated} = Lotus.list_tables("postgres")
      assert length(mutated) == length(full_tables) - 1
    end

    test "kind-specific event runs before :after_discover" do
      Middleware.compile(%{
        after_list_tables: [{OrderingProbePlug, [tag: :specific]}],
        after_discover: [{OrderingProbePlug, [tag: :unified]}]
      })

      Lotus.list_tables("postgres")

      # Message mailbox is FIFO; selective receive with the same pattern
      # pulls messages in send order.
      assert_received {:ordering_probe, first}
      assert_received {:ordering_probe, second}
      assert first == :specific
      assert second == :unified
    end

    test "halt in kind-specific event short-circuits :after_discover" do
      Middleware.compile(%{
        after_list_tables: [{HaltPlug, [reason: "specific halt"]}],
        after_discover: [{CountingPlug, []}]
      })

      assert {:error, "specific halt"} = Lotus.list_tables("postgres")
      refute_received :middleware_ran
    end

    test "registering only :after_discover works (no kind-specific event)" do
      Middleware.compile(%{
        after_discover: [{CountingPlug, []}]
      })

      assert {:ok, _} = Lotus.list_tables("postgres")
      assert_received :middleware_ran
    end

    test "registering only kind-specific event works (no :after_discover)" do
      Middleware.compile(%{
        after_list_tables: [{CountingPlug, []}]
      })

      assert {:ok, _} = Lotus.list_tables("postgres")
      assert_received :middleware_ran
    end

    test "middleware runs on every call, not only on first invocation" do
      Middleware.compile(%{
        after_discover: [{CountingPlug, []}]
      })

      {:ok, _} = Lotus.list_tables("postgres")
      {:ok, _} = Lotus.list_tables("postgres")
      {:ok, _} = Lotus.list_tables("postgres")

      assert_received :middleware_ran
      assert_received :middleware_ran
      assert_received :middleware_ran
    end

    test "context-sensitive middleware sees each per-call context" do
      Middleware.compile(%{
        after_discover: [{ContextCapturePlug, []}]
      })

      Lotus.list_tables("postgres", context: %{tenant: "acme"})
      Lotus.list_tables("postgres", context: %{tenant: "globex"})

      assert_received {:middleware_context, %{tenant: "acme"}}
      assert_received {:middleware_context, %{tenant: "globex"}}
    end
  end

  describe "exception inside middleware" do
    test "raised exception in before_query middleware surfaces as {:error, _}" do
      Middleware.compile(%{
        before_query: [{RaisingPlug, [message: "boom"]}]
      })

      assert {:error, %RuntimeError{message: "boom"}} =
               Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "exception stops subsequent middleware from running" do
      Middleware.compile(%{
        before_query: [
          {RaisingPlug, [message: "crash"]},
          {ContextCapturePlug, []}
        ]
      })

      assert {:error, %RuntimeError{message: "crash"}} =
               Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))

      refute_received {:middleware_context, _}
    end

    test "raised exception in after_query middleware surfaces as {:error, _}" do
      Middleware.compile(%{
        after_query: [{RaisingPlug, [message: "post-query crash"]}]
      })

      assert {:error, %RuntimeError{message: "post-query crash"}} =
               Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end
  end

  describe "scope in discovery middleware payloads" do
    test "scope flows through to kind-specific discovery events" do
      Middleware.compile(%{
        after_list_tables: [{ScopeCapturePlug, []}]
      })

      Lotus.list_tables("postgres", scope: %{role: :admin})
      assert_received {:middleware_scope, %{role: :admin}}
    end

    test "scope flows through to :after_discover unified event" do
      Middleware.compile(%{
        after_discover: [{ScopeCapturePlug, []}]
      })

      Lotus.list_schemas("postgres", scope: {:tenant, "acme"})
      assert_received {:middleware_scope, {:tenant, "acme"}}
    end

    test "scope is nil when not provided" do
      Middleware.compile(%{
        after_discover: [{ScopeCapturePlug, []}]
      })

      Lotus.list_tables("postgres")
      assert_received {:middleware_scope, nil}
    end
  end

  describe "scope-aware caching" do
    test "different scopes produce independent discovery results" do
      # Call with no scope — baseline
      {:ok, tables_no_scope} = Lotus.list_tables("postgres")
      refute tables_no_scope == []

      # Call with scope A — same underlying data, but independently cached
      {:ok, tables_scope_a} = Lotus.list_tables("postgres", scope: %{role: :admin})
      assert tables_scope_a == tables_no_scope

      # Call with scope B — also independently cached
      {:ok, tables_scope_b} = Lotus.list_tables("postgres", scope: {:tenant, "acme"})
      assert tables_scope_b == tables_no_scope

      # Verify no scope is identical to nil scope (backward compat)
      {:ok, tables_nil_scope} = Lotus.list_tables("postgres", scope: nil)
      assert tables_nil_scope == tables_no_scope
    end
  end

  describe "backward compatibility" do
    test "no middleware configured has zero overhead" do
      # No compile call - persistent_term is empty
      assert {:ok, %Result{}} = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "empty middleware map works" do
      Middleware.compile(%{})
      assert {:ok, %Result{}} = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1"))
    end

    test "existing callers without context work unchanged" do
      Middleware.compile(%{
        before_query: [{PassthroughPlug, []}]
      })

      # No context option passed
      assert {:ok, %Result{}} = Lotus.run_statement("SELECT 1")
      assert {:ok, tables} = Lotus.list_tables("postgres")
      refute tables == []
    end
  end
end
