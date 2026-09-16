defmodule Lotus.SQL.ValidatorTest do
  use Lotus.Case, async: false

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
end
