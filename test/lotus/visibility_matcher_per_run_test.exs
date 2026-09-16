defmodule Lotus.VisibilityMatcherPerRunTest do
  use Lotus.Case, async: true
  use Mimic

  defmodule CountingResolver do
    @moduledoc false
    @behaviour Lotus.Visibility.Resolver

    alias Lotus.Visibility.Resolvers.Static

    @impl true
    defdelegate schema_rules_for(name, scope), to: Static
    @impl true
    defdelegate table_rules_for(name, scope), to: Static
    @impl true
    defdelegate column_rules_for(name, scope), to: Static

    @impl true
    def matcher_for(name, scope) do
      send(self(), {:matcher_for, name, scope})
      Static.matcher_for(name, scope)
    end
  end

  test "a run asks the resolver for one matcher for preflight and one for the result" do
    stub(Lotus.Config, :visibility_resolver, fn -> CountingResolver end)

    assert {:ok, %{columns: ["id", "name", "email"]}} =
             Lotus.run_statement("SELECT id, name, email FROM test_users", [], repo: "postgres")

    assert_received {:matcher_for, "postgres", nil}
    assert_received {:matcher_for, "postgres", nil}
    refute_received {:matcher_for, "postgres", _}
  end
end
