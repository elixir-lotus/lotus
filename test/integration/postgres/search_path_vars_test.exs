defmodule Lotus.Integration.Postgres.SearchPathVarsTest do
  @moduledoc """
  A variable bound to a column of an unqualified table is typed from the
  table the search path resolves to, not only from its first schema.
  """

  use Lotus.Case, async: true

  @moduletag :postgres

  alias Lotus.Fixtures
  alias Lotus.Storage.Query
  alias Lotus.Test.Repo

  setup do
    user = Fixtures.insert_user(%{name: "Search Path"}, Repo)
    %{user: user}
  end

  defp query(search_path) do
    %Query{
      statement: "SELECT name FROM test_users WHERE id = {{id}}",
      variables: [%{name: "id", type: :text, default: nil}],
      data_source: "postgres",
      search_path: search_path
    }
  end

  test "a table in a later schema of the stored search path", %{user: user} do
    assert {:ok, %{rows: [["Search Path"]]}} =
             Lotus.run_query(query("reporting, public"), vars: %{"id" => to_string(user.id)})
  end

  test "the runtime search path overrides the stored one", %{user: user} do
    # The stored search path alone would not find test_users.
    assert {:ok, %{rows: [["Search Path"]]}} =
             Lotus.run_query(query("reporting"),
               vars: %{"id" => to_string(user.id)},
               search_path: "reporting, public"
             )
  end

  test "a table in the first schema of the search path still resolves" do
    query = %Query{
      statement: "SELECT count(*) FROM customers WHERE active = {{active}}",
      variables: [%{name: "active", type: :text, default: nil}],
      data_source: "postgres",
      search_path: "reporting, public"
    }

    assert {:ok, %{rows: [[0]]}} = Lotus.run_query(query, vars: %{"active" => "true"})
  end
end
