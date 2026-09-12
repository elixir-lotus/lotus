defmodule Lotus.MiddlewareBeforeExecuteTest do
  @moduledoc """
  `:before_execute` fires after sanitization and preflight pass and before the
  statement runs, carrying the relations preflight proved the statement
  touches.

  This is what an authorization plug that gates on tables needs. `:before_query`
  cannot serve it: it runs before the statement is analysed, on purpose, so a
  rewriting plug can still change what gets analysed.
  """

  use Lotus.Case

  alias Lotus.Middleware
  alias Lotus.Test.Schemas.User

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:before_execute, payload})
      {:cont, payload}
    end
  end

  defmodule HaltPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: {:halt, "denied by table authz"}
  end

  defmodule OrderPlug do
    @moduledoc false
    def init(event), do: event

    def call(payload, event) do
      send(self(), {:fired, event})
      {:cont, payload}
    end
  end

  defmodule RewritePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement} = payload, _opts) do
      {:cont,
       %{payload | statement: %{statement | body: "SELECT id FROM test_users WHERE id = 1"}}}
    end
  end

  setup do
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test"})
    Repo.insert!(%User{id: 2, name: "Grace", email: "grace@example.test"})

    :ok
  end

  test "the payload carries the relations preflight found" do
    Middleware.compile(%{before_execute: [{CapturePlug, []}]})

    assert {:ok, _result} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")

    assert_received {:before_execute, payload}
    assert payload.relations == [{"public", "test_users"}]
  end

  test "the payload carries the statement, source, context and vars" do
    Middleware.compile(%{before_execute: [{CapturePlug, []}]})

    assert {:ok, _result} =
             Lotus.run_statement("SELECT id FROM test_users", [],
               repo: "postgres",
               context: %{user_id: 7}
             )

    assert_received {:before_execute, payload}
    assert payload.source == "postgres"
    assert payload.context == %{user_id: 7}
    assert payload.vars == %{}
    assert payload.statement.body == "SELECT id FROM test_users"
  end

  test "a halt returns {:error, reason} and the statement never runs" do
    Middleware.compile(%{before_execute: [{HaltPlug, []}]})

    assert {:error, "denied by table authz"} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")
  end

  test "relations describe the statement a :before_query plug rewrote" do
    Middleware.compile(%{
      before_query: [{RewritePlug, []}],
      before_execute: [{CapturePlug, []}]
    })

    assert {:ok, result} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")

    assert result.rows == [[1]]

    assert_received {:before_execute, payload}
    assert payload.statement.body == "SELECT id FROM test_users WHERE id = 1"
    assert payload.relations == [{"public", "test_users"}]
  end

  test "fires after :before_query and before :after_query" do
    Middleware.compile(%{
      before_query: [{OrderPlug, :before_query}],
      before_execute: [{OrderPlug, :before_execute}],
      after_query: [{OrderPlug, :after_query}]
    })

    assert {:ok, _result} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")

    # Bound patterns, so the mailbox order is the assertion.
    assert_received {:fired, first}
    assert_received {:fired, second}
    assert_received {:fired, third}
    assert [first, second, third] == [:before_query, :before_execute, :after_query]
  end

  test "a statement blocked by preflight never reaches :before_execute" do
    Middleware.compile(%{before_execute: [{CapturePlug, []}]})

    assert {:error, msg} =
             Lotus.run_statement("SELECT * FROM lotus_queries", [], repo: "postgres")

    assert msg =~ "blocked table"
    refute_received {:before_execute, _payload}
  end
end
