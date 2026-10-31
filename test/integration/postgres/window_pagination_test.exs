defmodule Lotus.Integration.Postgres.WindowPaginationTest do
  use Lotus.Case, async: false

  @moduletag :postgres

  alias Lotus.Fixtures
  alias Lotus.Storage.Query
  alias Lotus.Test.Repo

  setup do
    u1 = Fixtures.insert_user(%{name: "Window A", email: "window_pg_1@example.com"}, Repo)
    u2 = Fixtures.insert_user(%{name: "Window B", email: "window_pg_2@example.com"}, Repo)
    u3 = Fixtures.insert_user(%{name: "Window C", email: "window_pg_3@example.com"}, Repo)

    on_exit(fn ->
      Repo.delete!(u1)
      Repo.delete!(u2)
      Repo.delete!(u3)
    end)

    :ok
  end

  describe "run_statement/3 with window pagination (postgres)" do
    test "pages results without total count" do
      sql = """
      SELECT name FROM test_users
      WHERE email IN ('window_pg_1@example.com','window_pg_2@example.com','window_pg_3@example.com')
      ORDER BY name
      """

      assert {:ok, result} =
               Lotus.run_statement(sql, [],
                 repo: "postgres",
                 window: [limit: 1, offset: 0, count: :none]
               )

      assert result.num_rows == 1
      assert result.rows == [["Window A"]]
      assert %{limit: 1, offset: 0} = result.meta[:window]
      assert is_nil(result.meta[:total_count])
      assert result.meta[:total_mode] in [:none, nil]
    end

    test "pages results with exact total count" do
      sql = """
      SELECT name FROM test_users
      WHERE email IN ('window_pg_1@example.com','window_pg_2@example.com','window_pg_3@example.com')
      ORDER BY name
      """

      assert {:ok, result} =
               Lotus.run_statement(sql, [],
                 repo: "postgres",
                 window: [limit: 2, offset: 1, count: :exact]
               )

      assert result.num_rows == 2
      assert result.rows == [["Window B"], ["Window C"]]
      assert %{limit: 2, offset: 1} = result.meta[:window]
      assert result.meta[:total_count] == 3
      assert result.meta[:total_mode] == :exact
    end
  end

  describe "run_query/2 with window pagination (postgres)" do
    test "pages results via saved-query struct (no total)" do
      q = %Query{
        statement: """
        SELECT name FROM test_users
        WHERE email IN ('window_pg_1@example.com','window_pg_2@example.com','window_pg_3@example.com')
        ORDER BY name
        """,
        variables: [],
        data_source: nil
      }

      assert {:ok, result} =
               Lotus.run_query(q, repo: "postgres", window: [limit: 1, offset: 1, count: :none])

      assert result.num_rows == 1
      assert result.rows == [["Window B"]]
      assert %{limit: 1, offset: 1} = result.meta[:window]
      assert is_nil(result.meta[:total_count])
    end

    test "pages results via saved-query struct (with total)" do
      q = %Query{
        statement: """
        SELECT name FROM test_users
        WHERE email IN ('window_pg_1@example.com','window_pg_2@example.com','window_pg_3@example.com')
        ORDER BY name
        """,
        variables: [],
        data_source: nil
      }

      assert {:ok, result} =
               Lotus.run_query(q, repo: "postgres", window: [limit: 2, offset: 0, count: :exact])

      assert result.num_rows == 2
      assert result.rows == [["Window A"], ["Window B"]]
      assert %{limit: 2, offset: 0} = result.meta[:window]
      assert result.meta[:total_count] == 3
      assert result.meta[:total_mode] == :exact
    end
  end

  describe "a statement that doesn't stay inside the window (postgres)" do
    test "is refused, so the window holds" do
      for sql <- [
            "SELECT name FROM test_users WHERE $1::int IS NOT NULL AND $2::int IS NOT NULL) AS x --",
            "SELECT name FROM test_users WHERE $1::int IS NOT NULL AND $2::int IS NOT NULL) AS x /*"
          ] do
        assert {:error, "Query has unbalanced parentheses or an unclosed comment"} =
                 Lotus.run_statement(sql, [], repo: "postgres", window: [limit: 1]),
               sql
      end
    end
  end
end
