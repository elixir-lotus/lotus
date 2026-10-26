defmodule Lotus.ColumnMaskingTest do
  # Column policies apply to result columns by name, whatever case the
  # database returns the name in.
  use Lotus.Case, async: true
  use Mimic

  alias Lotus.Fixtures
  alias Lotus.Test.MysqlRepo

  @redacted [action: :mask, mask: {:fixed, "REDACTED"}]

  setup do
    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{column: [{"test_users", "email", @redacted}]}
    end)

    :ok
  end

  defp run(sql, repo), do: Lotus.run_statement(sql, [], repo: repo)

  describe "a result column named in another case" do
    test "is masked on PostgreSQL when aliased to a quoted name" do
      Fixtures.setup_test_data()

      assert {:ok, %{columns: ["EMAIL"], rows: rows}} =
               run(~s|SELECT email AS "EMAIL" FROM test_users|, "postgres")

      assert rows != []
      assert Enum.all?(rows, &(&1 == ["REDACTED"]))
    end

    @tag :mysql
    test "is masked on MySQL, which returns the name as typed" do
      Fixtures.insert_user(%{metadata: nil}, MysqlRepo)

      assert {:ok, %{columns: ["EMAIL"], rows: rows}} =
               run("SELECT EMAIL FROM test_users", "mysql")

      assert rows != []
      assert Enum.all?(rows, &(&1 == ["REDACTED"]))
    end
  end
end
