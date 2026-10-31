defmodule Lotus.SQL.ValidatorTest do
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.SQL.Validator

  describe "validate/2 with postgres" do
    test "accepts PostgreSQL-specific ILIKE syntax" do
      assert :ok =
               Validator.validate(
                 "SELECT * FROM test_users WHERE name ILIKE '%test%'",
                 "postgres"
               )
    end

    test "accepts PostgreSQL array syntax" do
      assert :ok =
               Validator.validate(
                 "SELECT * FROM test_users WHERE id = ANY(ARRAY[1, 2, 3])",
                 "postgres"
               )
    end

    test "accepts PostgreSQL DATE_TRUNC function" do
      assert :ok =
               Validator.validate(
                 "SELECT DATE_TRUNC('month', inserted_at) FROM test_users",
                 "postgres"
               )
    end

    test "returns error for non-existent table" do
      assert {:error, _reason} =
               Validator.validate("SELECT * FROM nonexistent_table_xyz", "postgres")
    end

    test "returns error for invalid SQL" do
      assert {:error, _} = Validator.validate("NOT VALID SQL AT ALL", "postgres")
    end

    test "neutralizes {{variables}} before validation" do
      assert :ok =
               Validator.validate(
                 "SELECT * FROM test_users WHERE name ILIKE '%' || {{query}} || '%'",
                 "postgres"
               )
    end

    test "strips [[optional clauses]] before validation" do
      assert :ok =
               Validator.validate(
                 "SELECT * FROM test_users WHERE 1=1 [[AND name ILIKE '%' || {{name}} || '%']]",
                 "postgres"
               )
    end

    test "rejects conversational text" do
      assert {:error, _} =
               Validator.validate(
                 "I'm sorry, I cannot generate a query for that question.",
                 "postgres"
               )
    end
  end

  describe "validate/2 with sqlite" do
    @tag :sqlite
    test "accepts SQLite-specific strftime function" do
      assert :ok =
               Validator.validate(
                 "SELECT strftime('%Y-%m', inserted_at) FROM test_users",
                 "sqlite"
               )
    end

    @tag :sqlite
    test "accepts SQLite typeof function" do
      assert :ok =
               Validator.validate(
                 "SELECT typeof(name) FROM test_users",
                 "sqlite"
               )
    end

    @tag :sqlite
    test "returns error for invalid SQL" do
      assert {:error, _} = Validator.validate("NOT VALID SQL AT ALL", "sqlite")
    end
  end

  describe "validate/2 with mysql" do
    @tag :mysql
    test "accepts MySQL-specific IFNULL function" do
      assert :ok =
               Validator.validate(
                 "SELECT IFNULL(name, 'unknown') FROM test_users",
                 "mysql"
               )
    end

    @tag :mysql
    test "accepts MySQL backtick-quoted identifiers" do
      assert :ok =
               Validator.validate(
                 "SELECT `name` FROM `test_users`",
                 "mysql"
               )
    end

    @tag :mysql
    test "returns error for invalid SQL" do
      assert {:error, _} = Validator.validate("NOT VALID SQL AT ALL", "mysql")
    end
  end

  describe "the checks of a run" do
    test "a hidden table gets the run's refusal, whether its columns exist or not" do
      stub(Lotus.Config, :visibility_for_source_name, fn _ -> %{table: [deny: ["test_users"]]} end)

      for sql <- ["SELECT name FROM test_users", "SELECT nope FROM test_users"] do
        assert {:error, "Query touches blocked table(s): public.test_users"} =
                 Validator.validate(sql, "postgres"),
               sql
      end
    end

    test "the scope is the run's" do
      stub(Lotus.Visibility, :matcher_for, fn
        _source, :guest -> Lotus.Visibility.compile(%{table: [deny: ["test_users"]]})
        source, scope -> call_original(Lotus.Visibility, :matcher_for, [source, scope])
      end)

      assert :ok = Validator.validate("SELECT name FROM test_users", "postgres")

      assert {:error, "Query touches blocked table(s): " <> _} =
               Validator.validate("SELECT name FROM test_users", "postgres", scope: :guest)
    end

    test "a write is refused on a read-only source, and checked on a read-write run" do
      sql = "DELETE FROM test_users WHERE id = 0"

      assert {:error, "Only read-only queries are allowed" <> _} =
               Validator.validate(sql, "postgres")

      assert :ok = Validator.validate(sql, "postgres", read_only: false)
    end
  end
end
