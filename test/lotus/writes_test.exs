defmodule Lotus.WritesTest do
  use Lotus.Case, async: true

  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapter
  alias Lotus.Test.Schemas.User

  describe "Lotus.writes?/2" do
    test "a read does not write" do
      refute Lotus.writes?("SELECT * FROM test_users")
      refute Lotus.writes?("SELECT 1;")
      refute Lotus.writes?("WITH t AS (SELECT 1 AS n) SELECT n FROM t")
    end

    test "a statement read-only mode refuses writes" do
      assert Lotus.writes?("INSERT INTO test_users (name) VALUES ('a')")
      assert Lotus.writes?("update test_users set age = 1")
      assert Lotus.writes?("DELETE FROM test_users")
      assert Lotus.writes?("DROP TABLE test_users")
      assert Lotus.writes?("CREATE TABLE t (id int)")
      assert Lotus.writes?("SELECT set_config('app.x', '1', false)")
    end

    test "a statement that cannot run either way does not write" do
      refute Lotus.writes?("SELECT 1; DELETE FROM test_users")
    end

    test "variables and optional clauses are read as written" do
      assert Lotus.writes?("DELETE FROM test_users WHERE id = {{id}}")
      refute Lotus.writes?("SELECT * FROM test_users WHERE 1 = 1 [[AND id = {{id}}]]")
    end

    test "the statement does not run" do
      Repo.insert!(%User{name: "Ada", email: "ada@example.test", age: 36})

      assert Lotus.writes?("DELETE FROM test_users")
      assert Repo.aggregate(User, :count) == 1
    end

    test "an adapter without Preflight judges nothing a write" do
      adapter = %Adapter{
        name: "noop",
        module: Lotus.Test.NoOpAdapter,
        state: nil,
        source_type: :other
      }

      refute Runner.writes?(adapter, Statement.new("DELETE FROM t"))
    end

    @tag :mysql
    test "a MySQL source" do
      assert Lotus.writes?("INSERT INTO test_users (name) VALUES ('a')", repo: "mysql")
      refute Lotus.writes?("SELECT * FROM test_users", repo: "mysql")
    end

    @tag :sqlite
    test "a SQLite source" do
      assert Lotus.writes?("DELETE FROM products", repo: "sqlite")
      refute Lotus.writes?("SELECT * FROM products", repo: "sqlite")
    end
  end
end
