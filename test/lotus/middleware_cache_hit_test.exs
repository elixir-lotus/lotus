defmodule Lotus.MiddlewareCacheHitTest do
  @moduledoc """
  `:before_query` and `:after_query` run outside the result cache callback, so a
  cache hit does not skip them. Middleware is the documented place for
  context-dependent logic, and `:context` is not part of the cache key.
  """

  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Cache.ETS
  alias Lotus.{Config, Middleware}
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

  defmodule RewriteResultPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{result: result} = payload, _opts) do
      {:cont, %{payload | result: %{result | rows: [["rewritten"]]}}}
    end
  end

  defmodule TenantPredicatePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement, context: %{name: name}} = payload, _opts) do
      body = "SELECT name FROM test_users WHERE name = '#{name}'"
      {:cont, %{payload | statement: %{statement | body: body}}}
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

  test "a :before_query plug halts on a warm cache" do
    Middleware.compile(%{before_query: [{DenyUserPlug, []}]})

    assert {:ok, _result} = run(%{user: "a"})
    assert {:error, "denied"} = run(%{user: "b"})
  end

  test ":before_query runs on every call, cached or not" do
    Middleware.compile(%{before_query: [{RecordRunPlug, [event: :before]}]})

    assert {:ok, _} = run(%{user: "a"})
    assert {:ok, _} = run(%{user: "b"})

    assert_received {:before, %{user: "a"}}
    assert_received {:before, %{user: "b"}}
  end

  test ":after_query runs on every call, cached or not" do
    Middleware.compile(%{after_query: [{RecordRunPlug, [event: :after]}]})

    assert {:ok, _} = run(%{user: "a"})
    assert {:ok, _} = run(%{user: "b"})

    assert_received {:after, %{user: "a"}}
    assert_received {:after, %{user: "b"}}
  end

  test "an :after_query plug that changes the result does not write it back to the cache" do
    Middleware.compile(%{after_query: [{RewriteResultPlug, []}]})

    assert {:ok, first} = run(nil)
    assert first.rows == [["rewritten"]]

    Middleware.compile(%{})

    assert {:ok, second} = run(nil)
    assert second.rows == [["Ada"], ["Grace"]]
  end

  test "a statement a :before_query plug rewrote keys its own cache entry" do
    Middleware.compile(%{before_query: [{TenantPredicatePlug, []}]})

    assert {:ok, ada} = run(%{name: "Ada"})
    assert ada.rows == [["Ada"]]

    assert {:ok, grace} = run(%{name: "Grace"})
    assert grace.rows == [["Grace"]]
  end
end
