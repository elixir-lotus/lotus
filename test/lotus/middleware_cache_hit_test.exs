defmodule Lotus.MiddlewareCacheHitTest do
  @moduledoc """
  The query middleware runs outside the result cache callback, so a cache hit
  does not skip it. `:context` is not part of the cache key, and middleware is
  the documented place for context-dependent logic, so a plug that gates or
  audits per caller has to see every call.

  `:before_execute` gates on the relations preflight found, and those relations
  are stored with the result, so it fires on a hit as well.
  """

  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Cache.{ETS, Key}
  alias Lotus.{Config, Middleware, Result}
  alias Lotus.Preflight.Relations
  alias Lotus.Test.Schemas.User

  defmodule DenyUserPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{context: %{user: "b"}}, _opts), do: {:halt, "denied"}
    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule RecordRunPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, event: event) do
      send(self(), {event, payload[:context]})
      {:cont, payload}
    end
  end

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, event: event) do
      send(self(), {event, payload})
      {:cont, payload}
    end
  end

  defmodule RewriteResultPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{result: result} = payload, _opts) do
      {:cont, %{payload | result: %{result | rows: [["rewritten"]]}}}
    end
  end

  defmodule HaltResultPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: {:halt, "withheld"}
  end

  defmodule DenyRelationPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{relations: relations} = payload, denied: denied) do
      if Enum.any?(relations, &match?({_schema, ^denied}, &1)) do
        {:halt, "denied by table authz"}
      else
        {:cont, payload}
      end
    end
  end

  defmodule TenantBodyPlug do
    @moduledoc false
    def init(opts), do: opts

    # Replaces the whole statement, parameters included, the way a plug that
    # substitutes its own query has to.
    def call(%{statement: statement, context: %{name: name}} = payload, _opts) do
      body = "SELECT name FROM test_users WHERE name = '#{name}'"
      {:cont, %{payload | statement: %{statement | body: body, params: []}}}
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule TenantParamPlug do
    @moduledoc false
    def init(opts), do: opts

    # Filters through a bound parameter and leaves the statement text alone —
    # the shape a plug takes when it does not splice values into SQL.
    def call(%{statement: statement, context: %{name: name}} = payload, _opts) do
      {:cont, %{payload | statement: %{statement | params: [name]}}}
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  @statement "SELECT name FROM test_users ORDER BY name"

  setup do
    Mimic.copy(Lotus.Config)

    clear_cache_tables()

    on_exit(fn ->
      :persistent_term.erase({Lotus.Middleware, :compiled})
      clear_cache_tables()
    end)

    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> "middleware_cache_test" end)
    |> stub(:default_cache_profile, fn -> :results end)
    |> stub(:cache_profile_settings, fn _profile -> [ttl_ms: 30_000] end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test", age: 36})
    Repo.insert!(%User{id: 2, name: "Grace", email: "grace@example.test", age: 85})

    :ok
  end

  defp clear_cache_tables do
    for table <- [:lotus_cache, :lotus_cache_tags] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  defp run(context) do
    Lotus.run_statement(@statement, [], repo: "postgres", context: context)
  end

  # `[:lotus, :query, :stop]` brackets the phase the cache stores, so counting
  # those events counts executions. Asserting that middleware ran twice proves
  # nothing unless the second call was really served from the cache.
  defp count_executions(fun) do
    ref = make_ref()
    pid = self()
    handler = "#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:lotus, :query, :stop],
      fn _event, _measurements, _metadata, _config -> send(pid, {ref, :executed}) end,
      nil
    )

    try do
      fun.()
      count_messages(ref, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(ref, count) do
    receive do
      {^ref, :executed} -> count_messages(ref, count + 1)
    after
      0 -> count
    end
  end

  describe "the middleware around the cache callback" do
    test "a :before_query plug halts on a warm cache" do
      Middleware.compile(%{before_query: [{DenyUserPlug, []}]})

      assert {:ok, _result} = run(%{user: "a"})
      assert {:error, "denied"} = run(%{user: "b"})
    end

    test ":before_query and :after_query run on a call served from the cache" do
      Middleware.compile(%{
        before_query: [{RecordRunPlug, [event: :before]}],
        after_query: [{RecordRunPlug, [event: :after]}]
      })

      executions =
        count_executions(fn ->
          assert {:ok, _} = run(%{user: "a"})
          assert {:ok, _} = run(%{user: "b"})
        end)

      assert executions == 1

      assert_received {:before, %{user: "a"}}
      assert_received {:before, %{user: "b"}}
      assert_received {:after, %{user: "a"}}
      assert_received {:after, %{user: "b"}}
    end

    test "a halt on :after_query withholds a cached result from that caller alone" do
      assert {:ok, _} = run(nil)

      Middleware.compile(%{after_query: [{HaltResultPlug, []}]})
      assert {:error, "withheld"} = run(nil)

      Middleware.compile(%{})
      assert {:ok, result} = run(nil)
      assert result.rows == [["Ada"], ["Grace"]]
    end

    test "an :after_query plug that changes the result does not write it back to the cache" do
      Middleware.compile(%{after_query: [{RewriteResultPlug, []}]})

      assert {:ok, first} = run(nil)
      assert first.rows == [["rewritten"]]

      # Emptying the table proves the second call was served from the store: a
      # re-execution would return no rows at all.
      Repo.delete_all(User)
      Middleware.compile(%{})

      assert {:ok, second} = run(nil)
      assert second.rows == [["Ada"], ["Grace"]]
    end

    test "a statement a :before_query plug rewrote keys its own cache entry" do
      Middleware.compile(%{before_query: [{TenantBodyPlug, []}]})

      assert {:ok, ada} = run(%{name: "Ada"})
      assert ada.rows == [["Ada"]]

      assert {:ok, grace} = run(%{name: "Grace"})
      assert grace.rows == [["Grace"]]
    end

    test "a plug that rewrites only the bound parameters keys its own entry too" do
      Middleware.compile(%{before_query: [{TenantParamPlug, []}]})

      statement = "SELECT name FROM test_users WHERE name = $1"

      run = fn name ->
        Lotus.run_statement(statement, ["unused"], repo: "postgres", context: %{name: name})
      end

      assert {:ok, ada} = run.("Ada")
      assert ada.rows == [["Ada"]]

      assert {:ok, grace} = run.("Grace")
      assert grace.rows == [["Grace"]]
    end

    test "a stored query keys its entry on the rewritten statement as well" do
      Middleware.compile(%{before_query: [{TenantBodyPlug, []}]})

      {:ok, query} =
        Lotus.create_query(%{
          name: "Users by age",
          statement: "SELECT name FROM test_users WHERE age >= {{min_age}}",
          data_source: "postgres",
          variables: [%{name: "min_age", type: :number, default: "18"}]
        })

      assert {:ok, ada} = Lotus.run_query(query, context: %{name: "Ada"})
      assert ada.rows == [["Ada"]]

      assert {:ok, grace} = Lotus.run_query(query, context: %{name: "Grace"})
      assert grace.rows == [["Grace"]]
    end
  end

  describe ":before_execute on a cached result" do
    test "fires on a hit, with the relations stored alongside the result" do
      Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

      executions =
        count_executions(fn ->
          assert {:ok, _} = run(nil)
          assert {:ok, _} = run(nil)
        end)

      assert executions == 1

      assert_received {:before_execute, first}
      assert_received {:before_execute, second}
      assert first.relations == [{"public", "test_users"}]
      assert second.relations == first.relations
      assert second.statement.body == @statement
    end

    test "a halt on a hit withholds the cached result" do
      assert {:ok, _} = run(nil)

      Middleware.compile(%{before_execute: [{DenyRelationPlug, [denied: "test_users"]}]})

      assert {:error, "denied by table authz"} = run(nil)
    end

    test "the relations a plug sees on a hit are not a leftover from another statement" do
      Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

      assert {:ok, _} = run(nil)
      assert_received {:before_execute, _first}

      Relations.put([{"public", "decoy"}])

      assert {:ok, _} = run(nil)
      assert_received {:before_execute, second}
      assert second.relations == [{"public", "test_users"}]
    end
  end

  describe "an entry stored before results carried their relations" do
    test "is replaced, and :before_execute gates on the relations of the fresh run" do
      key =
        Key.result(
          @statement,
          %{__params__: []},
          [data_source: "postgres", search_path: nil, lotus_version: Lotus.version()],
          nil
        )

      stale = %Result{columns: ["name"], rows: [["stale"]], num_rows: 1}
      :ok = Lotus.Cache.put(key, stale, 30_000, [])

      Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

      assert {:ok, result} = run(nil)
      assert result.rows == [["Ada"], ["Grace"]]

      assert_received {:before_execute, payload}
      assert payload.relations == [{"public", "test_users"}]

      # The replacement carries the relations, so the next call is a hit that
      # still has something to gate on.
      executions = count_executions(fn -> assert {:ok, _} = run(nil) end)
      assert executions == 0

      assert_received {:before_execute, from_cache}
      assert from_cache.relations == [{"public", "test_users"}]
    end
  end

  describe "preflight relations across a cached call" do
    # The process dictionary is not a source of relations for any phase: a
    # value another statement left there never reaches a payload, on a hit or
    # on a miss.
    test "a call served from the cache carries the stored relations, not stranded ones" do
      Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

      assert {:ok, _} = run(nil)
      assert_received {:before_execute, %{origin: :executed}}

      Relations.put([{"public", "decoy"}])

      assert {:ok, _} = run(nil)
      assert_received {:before_execute, %{origin: :cached, relations: [{"public", "test_users"}]}}
    end

    test "a :before_query payload carries no relations at all" do
      Middleware.compile(%{before_query: [{CapturePlug, [event: :before_query]}]})

      Relations.put([{"public", "test_users"}])

      assert {:ok, _} = run(nil)
      assert_received {:before_query, payload}
      refute Map.has_key?(payload, :relations)
    end

    # `CAST(email AS integer)` plans fine and fails only once a row is
    # evaluated, so preflight passes and records its relations before execution
    # fails.
    test "a statement that fails during execution clears its relations" do
      failing = "SELECT CAST(email AS integer) AS boom FROM test_users"

      assert {:error, _} = Lotus.run_statement(failing, [], repo: "postgres")
      assert Relations.get() == []
    end
  end

  describe "pagination" do
    test "the page and its count are built from the rewritten statement" do
      Middleware.compile(%{before_query: [{TenantBodyPlug, []}]})

      assert {:ok, result} =
               Lotus.run_statement(@statement, [],
                 repo: "postgres",
                 context: %{name: "Ada"},
                 window: [limit: 10, count: :exact]
               )

      assert result.rows == [["Ada"]]
      assert result.meta.total_count == 1
    end
  end
end
