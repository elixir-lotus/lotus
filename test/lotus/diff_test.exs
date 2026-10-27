defmodule Lotus.DiffTest do
  use Lotus.Case

  import Lotus.Fixtures

  alias Lotus.Diff
  alias Lotus.Storage.Query

  defp result(columns, rows), do: %{columns: columns, rows: rows}

  describe "compare/3" do
    test "rows added, removed and changed, on the key" do
      before = result(~w(id name total), [[1, "a", 10], [2, "b", 20], [3, "c", 30]])
      after_ = result(~w(id name total), [[2, "b", 25], [3, "c", 30], [4, "d", 40]])

      assert {:ok, diff} = Diff.compare(before, after_, ["id"])
      assert diff.added == [%{"id" => 4, "name" => "d", "total" => 40}]
      assert diff.removed == [%{"id" => 1, "name" => "a", "total" => 10}]

      assert [%{key: [k], columns: ["total"], before: %{"total" => 20}, after: %{"total" => 25}}] =
               diff.changed

      assert Decimal.equal?(k, 2)
      assert diff.unchanged == 1
      assert {diff.before_count, diff.after_count} == {3, 3}
    end

    test "compares the columns both have, and equal numbers as equal" do
      before = result(~w(id total email), [[1, Decimal.new("1.50"), "x"]])
      after_ = result(~w(id total region), [[1, Decimal.new("1.5"), "EU"]])

      assert {:ok, %{columns: ["id", "total"], changed: [], unchanged: 1}} =
               Diff.compare(before, after_, ["id"])

      assert {:ok, %{unchanged: 1}} =
               Diff.compare(result(["id"], [[1.0]]), result(["id"], [[1]]), ["id"])
    end

    test "a key of several columns" do
      before = result(~w(a b n), [[1, "x", 1], [1, "y", 2]])
      after_ = result(~w(a b n), [[1, "y", 3]])

      assert {:ok, %{removed: [%{"b" => "x"}], changed: [%{columns: ["n"]}]}} =
               Diff.compare(before, after_, ["a", "b"])
    end

    test "a key a result lacks, or that is not unique" do
      assert {:error, {:missing_key, :after, ["id"]}} =
               Diff.compare(result(["id"], []), result(["name"], []), ["id"])

      assert {:error, {:duplicate_key, :before, _}} =
               Diff.compare(result(["id"], [[1], [1]]), result(["id"], []), ["id"])
    end
  end

  describe "Lotus.diff/3" do
    setup do
      setup_test_data()
      :ok
    end

    defp query(statement), do: %Query{statement: statement, data_source: "postgres"}

    test "runs both queries and compares their rows" do
      before = query("SELECT name, age FROM test_users ORDER BY name")
      after_ = query("SELECT name, age + 1 AS age FROM test_users WHERE age > 40 ORDER BY name")

      assert {:ok, diff} = Lotus.diff({before, []}, {after_, []}, key: "name")
      assert Enum.map(diff.removed, & &1["name"]) == ["Hunter S. Thompson"]
      assert diff.added == []
      assert Enum.all?(diff.changed, &(&1.columns == ["age"]))
      assert length(diff.changed) == 2
    end

    test "variables per side" do
      q = %Query{
        statement: "SELECT name FROM test_users WHERE age > {{min}}",
        data_source: "postgres",
        variables: [%Lotus.Storage.QueryVariable{name: "min", type: :number}]
      }

      assert {:ok, %{removed: [%{"name" => "Hunter S. Thompson"}]}} =
               Lotus.diff({q, vars: %{"min" => "0"}}, {q, vars: %{"min" => "40"}}, key: "name")
    end

    test "too many rows, no key, or a query that fails" do
      q = query("SELECT name FROM test_users")

      assert {:error, {:too_many_rows, 1}} = Lotus.diff({q, []}, {q, []}, key: "name", limit: 1)
      assert {:error, :no_key} = Lotus.diff({q, []}, {q, []}, [])

      assert {:error, _} =
               Lotus.diff({q, []}, {query("SELECT nope FROM test_users"), []}, key: "name")
    end

    test "runs read only" do
      q = query("DELETE FROM test_users RETURNING name")
      assert {:error, _} = Lotus.diff({q, []}, {q, []}, key: "name")
      assert Repo.aggregate(Lotus.Test.Schemas.User, :count) > 0
    end
  end
end
