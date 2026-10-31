defmodule Lotus.PreflightErrorVisibilityTest do
  # A statement that names a hidden table is refused the same way whether
  # the source could plan it or not, so its error tells nothing of the
  # table's columns.
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Storage.{Query, QueryVariable}

  setup do
    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{table: [deny: ["test_users"]]}
    end)

    :ok
  end

  for repo <- ["postgres", "sqlite", "mysql"] do
    @tag String.to_atom(repo)
    test "a present and an absent column of a hidden table get the same refusal (#{repo})" do
      for sql <- [
            "SELECT name FROM test_users",
            "SELECT no_such_column FROM test_users",
            "SELECT 1 WHERE EXISTS (SELECT no_such_column FROM test_users)",
            "SELECT no_such_column FROM TEST_USERS"
          ] do
        assert {:error, "Query touches blocked table(s): " <> table} =
                 Lotus.run_statement(sql, [], repo: unquote(repo)),
               sql

        assert table =~ "test_users"
        refute table =~ "no_such_column"
      end
    end
  end

  test "the source's error still reaches a statement over visible tables" do
    assert {:error, message} = Lotus.run_statement("SELECT no_such_column FROM test_posts", [])
    assert message =~ "no_such_column"
  end

  test "a variable compared with a hidden table's column tells nothing of its type" do
    query = %Query{
      name: "Probe",
      statement: "SELECT 1 FROM test_users WHERE age = {{v}}",
      data_source: "postgres",
      variables: [%QueryVariable{name: "v", type: :text}]
    }

    assert {:error, "Query touches blocked table(s): public.test_users"} =
             Lotus.run_query(query, vars: %{"v" => "abc"})
  end
end
