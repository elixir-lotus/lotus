defmodule Lotus.ColumnPolicyUsageTest do
  # Column policies apply by result column name, so a statement that renames
  # or transforms a protected column is refused before it runs (#321).
  use Lotus.Case, async: true
  use Mimic

  alias Lotus.Fixtures

  setup do
    Fixtures.setup_test_data()

    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{column: [{"public", "test_users", "email", [action: :mask, mask: {:fixed, "REDACTED"}]}]}
    end)

    :ok
  end

  defp run(sql, opts \\ []), do: Lotus.run_statement(sql, [], [repo: "postgres"] ++ opts)

  test "a protected column selected as is is masked" do
    assert {:ok, %{columns: ["name", "email"], rows: rows}} =
             run("SELECT name, email FROM test_users ORDER BY name")

    assert Enum.all?(rows, fn [_name, email] -> email == "REDACTED" end)
  end

  test "masking holds through pagination" do
    assert {:ok, %{rows: [[_name, "REDACTED"] | _]}} =
             run("SELECT name, email FROM test_users", window: [limit: 2, count: :exact])
  end

  test "renaming or transforming a protected column is refused" do
    for sql <- [
          "SELECT email AS e FROM test_users",
          "SELECT upper(email) FROM test_users",
          "SELECT email || '' AS x FROM test_users",
          "SELECT name FROM test_users WHERE email LIKE '%@%'"
        ] do
      assert {:error, "Query uses protected column email" <> _} = run(sql), sql
    end
  end

  test "a cast that would echo the value in the error is refused before it runs" do
    assert {:error, message} = run("SELECT email::int FROM test_users")

    refute message =~ "@"
    assert message =~ "protected column email"
  end

  test "whole rows of the table are refused" do
    assert {:error, "Query reads whole rows of u" <> _} =
             run("SELECT to_json(u) FROM test_users u")
  end

  test "a NATURAL join over the table is refused before it runs" do
    for sql <- [
          "SELECT name FROM test_users NATURAL JOIN (SELECT 'x' AS email) p",
          "SELECT name FROM test_users NATURAL LEFT JOIN (SELECT 'x' AS email) p"
        ] do
      assert {:error, "Query joins with NATURAL " <> _} = run(sql), sql
    end
  end
end
