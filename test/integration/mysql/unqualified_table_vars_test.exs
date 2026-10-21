defmodule Lotus.Integration.Mysql.UnqualifiedTableVarsTest do
  @moduledoc """
  A variable bound to a column of an unqualified MySQL table is typed from
  that column, looked up in the connection's database. Before, the lookup
  used a "public" schema MySQL doesn't have, so the value was never cast.
  """

  use Lotus.Case, async: false

  @moduletag :mysql

  alias Lotus.Fixtures
  alias Lotus.Storage.Query
  alias Lotus.Test.MysqlRepo

  setup do
    Fixtures.insert_user(%{name: "Active", email: "active@example.com", active: true}, MysqlRepo)

    Fixtures.insert_user(
      %{name: "Inactive", email: "inactive@example.com", active: false},
      MysqlRepo
    )

    :ok
  end

  defp run(statement, vars) do
    query = %Query{
      statement: statement,
      variables: Enum.map(vars, fn {name, _} -> %{name: name, type: :text, default: nil} end),
      data_source: "mysql"
    }

    Lotus.run_query(query, vars: vars)
  end

  test "a tinyint(1) column casts \"true\" to a boolean" do
    # Uncast, MySQL compares the tinyint with the string 'true', which it
    # reads as 0, and returns the inactive user.
    assert {:ok, %{rows: [["Active"]]}} =
             run("SELECT name FROM test_users WHERE active = {{active}}", %{"active" => "true"})
  end

  test "an int column rejects a value that is not an integer" do
    assert {:error, message} =
             run("SELECT name FROM test_users WHERE id = {{id}}", %{"id" => "abc"})

    assert message =~ "Invalid integer format"
  end
end
