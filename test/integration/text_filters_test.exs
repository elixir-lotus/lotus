defmodule Lotus.Integration.TextFiltersTest do
  # `:contains`, `:starts_with` and `:ends_with` on each SQL database: text
  # as written (`%` and `_` are themselves) and without regard to case.
  use Lotus.Case, async: false

  alias Lotus.Fixtures
  alias Lotus.Query.Filter
  alias Lotus.Storage.Query

  @names ["Ann Lee", "ANNA Bell", "Joanne", "50% off", "500 off", "user_id", "userXid", "a!b"]

  for {source, repo, tag} <- [
        {nil, Lotus.Test.Repo, :postgres},
        {"mysql", Lotus.Test.MysqlRepo, :mysql},
        {"sqlite", Lotus.Test.SqliteRepo, :sqlite}
      ] do
    describe "#{tag}" do
      @describetag tag

      setup do
        for name <- @names, do: Fixtures.insert_user(%{name: name}, unquote(repo))
        :ok
      end

      test "contains, without regard to case" do
        assert names(unquote(source), :contains, "ann") == ["ANNA Bell", "Ann Lee", "Joanne"]
      end

      test "starts with and ends with" do
        assert names(unquote(source), :starts_with, "ann") == ["ANNA Bell", "Ann Lee"]
        assert names(unquote(source), :ends_with, "NE") == ["Joanne"]
      end

      test "% and _ are themselves, not wildcards" do
        assert names(unquote(source), :contains, "0%") == ["50% off"]
        assert names(unquote(source), :contains, "_") == ["user_id"]
        assert names(unquote(source), :starts_with, "user_") == ["user_id"]
      end

      test "the escape character is itself" do
        assert names(unquote(source), :contains, "!") == ["a!b"]
        assert names(unquote(source), :ends_with, "!b") == ["a!b"]
      end

      test ":like keeps its pattern as it is" do
        assert names(unquote(source), :like, "user_id") == ["userXid", "user_id"]
      end
    end
  end

  defp names(source, op, value) do
    query = %Query{statement: "SELECT name FROM test_users", data_source: source}

    {:ok, %{rows: rows}} = Lotus.run_query(query, filters: [Filter.new("name", op, value)])

    rows |> Enum.map(&hd/1) |> Enum.sort()
  end
end
