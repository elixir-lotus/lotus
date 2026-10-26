defmodule Lotus.ColumnMaskingTest do
  # Column policies apply to result columns by name, whatever case the
  # database returns the name in, and by the column's own relation when the
  # statement says which it is.
  use Lotus.Case, async: true
  use Mimic

  alias Lotus.Fixtures
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.{MysqlRepo, Repo}

  @redacted [action: :mask, mask: {:fixed, "REDACTED"}]
  @join "FROM test_users u JOIN test_posts p ON p.user_id = u.id"

  defp rules(column_rules) do
    stub(Lotus.Config, :visibility_for_source_name, fn _source -> %{column: column_rules} end)
    :ok
  end

  defp run(sql, repo \\ "postgres"), do: Lotus.run_statement(sql, [], repo: repo)

  defp redacted?(rows),
    do: rows != [] and Enum.all?(rows, &Enum.all?(&1, fn v -> v == "REDACTED" end))

  defp raw?(rows), do: rows != [] and Enum.all?(rows, &Enum.all?(&1, fn v -> v != "REDACTED" end))

  describe "a result column named in another case" do
    setup do
      rules([{"test_users", "email", @redacted}])
    end

    test "is masked on PostgreSQL when aliased to a quoted name" do
      Fixtures.setup_test_data()

      assert {:ok, %{columns: ["EMAIL"], rows: rows}} =
               run(~s|SELECT email AS "EMAIL" FROM test_users|)

      assert redacted?(rows)
    end

    @tag :mysql
    test "is masked on MySQL, which returns the name as typed" do
      Fixtures.insert_user(%{metadata: nil}, MysqlRepo)

      assert {:ok, %{columns: ["EMAIL"], rows: rows}} =
               run("SELECT EMAIL FROM test_users", "mysql")

      assert redacted?(rows)
    end
  end

  # `inserted_at` is a column of both tables: the posts' is allowed, the
  # users' masked. The rule order must not matter.
  for {order, column_rules} <- [
        posts_first: [
          {"test_posts", "inserted_at", :allow},
          {"test_users", "inserted_at", @redacted}
        ],
        users_first: [
          {"test_users", "inserted_at", @redacted},
          {"test_posts", "inserted_at", :allow}
        ]
      ] do
    describe "a column of two joined tables, #{order}" do
      setup do
        Fixtures.setup_test_data()
        rules(unquote(Macro.escape(column_rules)))
      end

      test "is masked when qualified by the table that masks it" do
        assert {:ok, %{rows: rows}} = run("SELECT u.inserted_at #{@join}")
        assert redacted?(rows)
      end

      test "is not masked when qualified by the table that allows it" do
        assert {:ok, %{rows: rows}} = run("SELECT p.inserted_at #{@join}")
        assert raw?(rows)
      end

      test "each qualified column gets its own table's policy" do
        assert {:ok, %{columns: ["inserted_at", "inserted_at"], rows: rows}} =
                 run("SELECT p.inserted_at, u.inserted_at AS inserted_at #{@join}")

        assert Enum.all?(rows, fn [posted, joined] ->
                 posted != "REDACTED" and joined == "REDACTED"
               end)
      end

      test "is masked through *, since the name doesn't tell the table" do
        assert {:ok, %{columns: columns, rows: rows}} = run("SELECT * #{@join}")

        for {"inserted_at", i} <- Enum.with_index(columns) do
          assert Enum.all?(rows, &(Enum.at(&1, i) == "REDACTED"))
        end
      end

      test "is masked when a subquery outputs it" do
        sql =
          "SELECT s.inserted_at FROM (SELECT p.inserted_at, p.user_id FROM test_posts p) s " <>
            "JOIN test_users u ON u.id = s.user_id"

        assert {:ok, %{rows: rows}} = run(sql)
        assert redacted?(rows)
      end

      test "keeps its own policy in a single-table statement" do
        assert {:ok, %{rows: users}} = run("SELECT inserted_at FROM test_users")
        assert redacted?(users)

        assert {:ok, %{rows: posts}} = run("SELECT inserted_at FROM test_posts")
        assert raw?(posts)
      end

      test "is masked the same through the runner and a stream" do
        adapter = EctoAdapter.wrap("postgres", Repo)

        assert {:ok, %{rows: masked}} =
                 Runner.run_statement(adapter, Statement.new("SELECT u.inserted_at #{@join}"))

        assert redacted?(masked)

        assert {:ok, %{rows: allowed}} =
                 Runner.run_statement(adapter, Statement.new("SELECT p.inserted_at #{@join}"))

        assert raw?(allowed)

        assert {:ok, streamed} =
                 Lotus.stream_statement(
                   "SELECT u.inserted_at, p.inserted_at #{@join}",
                   [],
                   [repo: "postgres"],
                   fn chunks -> Enum.flat_map(chunks, & &1.rows) end
                 )

        assert Enum.all?(streamed, fn [joined, posted] ->
                 joined == "REDACTED" and posted != "REDACTED"
               end)
      end
    end
  end

  describe "an unqualified column over a join" do
    setup do
      Fixtures.setup_test_data()
      rules([{"test_posts", "email", :allow}, {"test_users", "email", @redacted}])
    end

    test "gets the strictest policy of the joined tables" do
      assert {:ok, %{rows: rows}} = run("SELECT email #{@join}")
      assert redacted?(rows)
    end
  end
end
