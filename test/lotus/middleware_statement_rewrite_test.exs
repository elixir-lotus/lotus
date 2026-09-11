defmodule Lotus.MiddlewareStatementRewriteTest do
  @moduledoc """
  A `:before_query` plug can rewrite the statement it is handed, and the
  rewritten statement is what gets sanitized, authorized and executed.

  This is what row-level security and tenant predicates need: the plug adds a
  restriction, and core must not execute the original text it was given.
  """

  use Lotus.Case

  alias Lotus.Middleware
  alias Lotus.Test.Schemas.User

  defmodule TenantPredicatePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement} = payload, _opts) do
      rewritten = %{statement | body: statement.body <> " WHERE id = 1"}
      {:cont, %{payload | statement: rewritten}}
    end
  end

  defmodule PassthroughPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule RewriteToBlockedTablePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement} = payload, _opts) do
      rewritten = %{statement | body: "SELECT * FROM lotus_queries"}
      {:cont, %{payload | statement: rewritten}}
    end
  end

  setup do
    # Middleware.compile(%{}) hits the no-op clause and leaves the previously
    # compiled pipeline in place, so reset by erasing the term itself.
    on_exit(fn ->
      :persistent_term.erase({Lotus.Middleware, :compiled})
    end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test"})
    Repo.insert!(%User{id: 2, name: "Grace", email: "grace@example.test"})

    :ok
  end

  test "a rewritten statement is the one executed" do
    {:ok, unfiltered} =
      Lotus.run_statement("SELECT id FROM test_users ORDER BY id", [], repo: "postgres")

    Middleware.compile(%{before_query: [{TenantPredicatePlug, []}]})

    assert {:ok, filtered} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")

    # The plug appended WHERE id = 1, so the result must be narrower than the
    # same statement run without the plug.
    assert unfiltered.num_rows == 2
    assert filtered.num_rows == 1
    assert filtered.rows == [[1]]
  end

  test "a plug that returns the payload untouched still works" do
    Middleware.compile(%{before_query: [{PassthroughPlug, []}]})

    assert {:ok, result} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")

    assert is_integer(result.num_rows)
  end

  test "a rewrite onto a blocked table is caught, not executed" do
    Middleware.compile(%{before_query: [{RewriteToBlockedTablePlug, []}]})

    assert {:error, message} =
             Lotus.run_statement("SELECT id FROM test_users", [], repo: "postgres")

    assert message =~ "blocked table"
  end
end
