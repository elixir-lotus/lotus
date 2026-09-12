defmodule Lotus.MiddlewareCountRunTest do
  @moduledoc """
  `window: [count: :exact]` runs a second statement, derived from the page
  statement, to compute `meta.total_count`. That run is Lotus's own and not
  the caller's, so it must carry the caller's options into the pipeline and
  fire only the events that make sense for a derived statement:

    * `:before_query` fires once, for the page statement. The count statement
      is derived from what that hook returned, so running it again would apply
      a rewriting plug twice.
    * `:before_execute` fires for the page and for the count, with the caller's
      context and vars, because it authorises against relations and the count
      touches the same tables.
    * `:after_query` fires once, for the page result. The count has no
      user-facing result to shape.
    * Preflight sees the caller's scope on both runs.
  """

  use Lotus.Case
  use Mimic

  alias Lotus.Middleware
  alias Lotus.Test.Schemas.User

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, event: event) do
      send(self(), {event, payload})
      {:cont, payload}
    end
  end

  defmodule HaltCountPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: %{body: body}} = payload, _opts) do
      if String.contains?(body, "COUNT("),
        do: {:halt, "count refused"},
        else: {:cont, payload}
    end
  end

  defmodule RecordingResolver do
    @moduledoc false
    @behaviour Lotus.Visibility.Resolver

    @impl true
    def schema_rules_for(_source, _scope), do: []

    @impl true
    def table_rules_for(_source, scope) do
      send(self(), {:table_rules_for, scope})
      []
    end

    @impl true
    def column_rules_for(_source, _scope), do: []
  end

  @statement "SELECT name FROM test_users ORDER BY name"
  @window [limit: 1, count: :exact]

  setup :set_mimic_from_context

  setup do
    Mimic.copy(Lotus.Config)
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test", age: 36})
    Repo.insert!(%User{id: 2, name: "Grace", email: "grace@example.test", age: 85})

    :ok
  end

  defp run(opts) do
    Lotus.run_statement(@statement, [], Keyword.merge([repo: "postgres", window: @window], opts))
  end

  test ":before_query fires once per paginated call, with the caller's context" do
    Middleware.compile(%{before_query: [{CapturePlug, [event: :before_query]}]})

    assert {:ok, result} = run(context: %{user: "a"})
    assert result.meta.total_count == 2

    assert_received {:before_query, %{context: %{user: "a"}}}
    refute_received {:before_query, _}
  end

  test ":before_execute fires for the page and for the count, both with the caller's context" do
    Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

    assert {:ok, result} = run(context: %{user: "a"})
    assert result.meta.total_count == 2

    assert_received {:before_execute, %{context: %{user: "a"}} = page}
    assert_received {:before_execute, %{context: %{user: "a"}} = count}
    refute_received {:before_execute, _}

    assert page.relations == [{"public", "test_users"}]
    assert count.relations == [{"public", "test_users"}]
    assert String.contains?(count.statement.body, "COUNT(")
  end

  test ":before_execute for the count carries the caller's vars" do
    {:ok, query} =
      Lotus.create_query(%{
        name: "Users by age",
        statement: "SELECT name FROM test_users WHERE age >= {{min_age}}",
        data_source: "postgres",
        variables: [%{name: "min_age", type: :number, default: "18"}]
      })

    Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

    assert {:ok, result} = Lotus.run_query(query, vars: %{"min_age" => 40}, window: @window)
    assert result.meta.total_count == 1

    assert_received {:before_execute, %{vars: %{"min_age" => 40}}}
    assert_received {:before_execute, %{vars: %{"min_age" => 40}}}
    refute_received {:before_execute, _}
  end

  test ":after_query fires once, for the page result only" do
    Middleware.compile(%{after_query: [{CapturePlug, [event: :after_query]}]})

    assert {:ok, result} = run(context: %{user: "a"})
    assert result.meta.total_count == 2

    assert_received {:after_query, %{context: %{user: "a"}}}
    refute_received {:after_query, _}
  end

  test "preflight sees the caller's scope on the page run and on the count run" do
    stub(Lotus.Config, :visibility_resolver, fn -> RecordingResolver end)

    assert {:ok, result} = run(scope: %{tenant_id: 7})
    assert result.meta.total_count == 2

    assert_received {:table_rules_for, %{tenant_id: 7}}
    assert_received {:table_rules_for, %{tenant_id: 7}}
    refute_received {:table_rules_for, nil}
  end

  test "a plug that halts the count leaves total_count nil and the page intact" do
    Middleware.compile(%{before_execute: [{HaltCountPlug, []}]})

    assert {:ok, result} = run(context: %{user: "a"})
    assert result.rows == [["Ada"]]
    assert result.meta.total_count == nil
  end
end
