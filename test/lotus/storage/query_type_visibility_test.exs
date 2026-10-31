defmodule Lotus.Storage.QueryTypeVisibilityTest do
  # A variable is typed from its column only where the caller may see the
  # column's table, so a cast error tells nothing of a hidden one.
  use Lotus.Case, async: false
  use Mimic

  @moduletag :sqlite

  alias Lotus.Storage.{Query, QueryVariable}

  @query %Query{
    name: "Probe",
    statement: "SELECT 1 FROM test_users WHERE age = {{v}}",
    data_source: "sqlite",
    variables: [%QueryVariable{name: "v", type: :text}]
  }

  defp deny(tables) do
    stub(Lotus.Config, :visibility_for_source_name, fn _source -> %{table: [deny: tables]} end)
  end

  test "a variable bound to a visible table's column is typed by it" do
    deny([])

    refute Lotus.can_run?(@query, vars: %{"v" => "abc"})

    assert {:error, "Invalid integer format" <> _} =
             Lotus.run_query(@query, vars: %{"v" => "abc"})
  end

  test "a variable bound to a hidden table's column is text, and the run is refused" do
    deny(["test_users"])

    assert Lotus.can_run?(@query, vars: %{"v" => "abc"})

    assert {:error, "Query touches blocked table(s): " <> _} =
             Lotus.run_query(@query, vars: %{"v" => "abc"})
  end

  test "the scope decides, as it does for the run" do
    stub(Lotus.Config, :visibility_for_source_name, fn _source -> %{} end)

    stub(Lotus.Visibility, :allowed_relation?, fn
      _source, {_schema, "test_users"}, :restricted ->
        false

      source, relation, scope ->
        call_original(Lotus.Visibility, :allowed_relation?, [source, relation, scope])
    end)

    assert {:ok, _statement} = Query.compile(@query, %{"v" => "abc"}, scope: :restricted)
    assert {:error, "Invalid integer format" <> _} = Query.compile(@query, %{"v" => "abc"})
  end
end
