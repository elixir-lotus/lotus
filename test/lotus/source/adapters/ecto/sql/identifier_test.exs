defmodule Lotus.Source.Adapters.Ecto.SQL.IdentifierTest do
  use ExUnit.Case, async: true

  alias Lotus.Source.Adapters.Ecto.SQL.Identifier

  describe "parse_table_name/1" do
    test "parses unqualified table name" do
      assert {nil, "users"} = Identifier.parse_table_name("users")
    end

    test "parses schema-qualified table name" do
      assert {"public", "users"} = Identifier.parse_table_name("public.users")
    end

    test "handles extra dots in table name" do
      assert {"public", "users.extra"} = Identifier.parse_table_name("public.users.extra")
    end
  end

  describe "validate_identifier/2" do
    test "accepts valid identifiers" do
      assert :ok = Identifier.validate_identifier("users", "table name")
      assert :ok = Identifier.validate_identifier("_private", "table name")
      assert :ok = Identifier.validate_identifier("table_123", "table name")
      assert :ok = Identifier.validate_identifier("A", "table name")
    end

    test "rejects identifiers starting with a digit" do
      assert {:error, msg} = Identifier.validate_identifier("123abc", "table name")
      assert msg =~ "Invalid table name"
    end

    test "rejects identifiers with special characters" do
      assert {:error, _} = Identifier.validate_identifier("users; DROP TABLE", "table name")
      assert {:error, _} = Identifier.validate_identifier("table-name", "column name")
      assert {:error, _} = Identifier.validate_identifier("name space", "schema name")
    end

    test "rejects empty string" do
      assert {:error, _} = Identifier.validate_identifier("", "table name")
    end
  end

  describe "validate_identifier!/2" do
    test "returns :ok for valid identifiers" do
      assert :ok = Identifier.validate_identifier!("users", "table name")
    end

    test "raises ArgumentError for invalid identifiers" do
      assert_raise ArgumentError, ~r/Invalid table name/, fn ->
        Identifier.validate_identifier!("users; DROP TABLE", "table name")
      end
    end
  end

  describe "validate_table_parts/2" do
    test "validates unqualified table name" do
      assert :ok = Identifier.validate_table_parts(nil, "users")
    end

    test "validates schema-qualified table name" do
      assert :ok = Identifier.validate_table_parts("public", "users")
    end

    test "rejects invalid table name" do
      assert {:error, _} = Identifier.validate_table_parts(nil, "bad; table")
    end

    test "rejects invalid schema name" do
      assert {:error, msg} = Identifier.validate_table_parts("bad schema", "users")
      assert msg =~ "Invalid schema name"
    end

    test "rejects invalid table with valid schema" do
      assert {:error, msg} = Identifier.validate_table_parts("public", "bad-table")
      assert msg =~ "Invalid table name"
    end
  end

  describe "validate_search_path!/1" do
    test "accepts single schema" do
      assert :ok = Identifier.validate_search_path!("public")
    end

    test "accepts comma-separated schemas" do
      assert :ok = Identifier.validate_search_path!("public, reporting, analytics")
    end

    test "accepts schemas without spaces" do
      assert :ok = Identifier.validate_search_path!("public,reporting")
    end

    test "rejects invalid characters in search path" do
      assert_raise ArgumentError, ~r/Invalid search_path entry/, fn ->
        Identifier.validate_search_path!("public; DROP TABLE users --")
      end
    end

    test "rejects SQL injection attempts" do
      assert_raise ArgumentError, fn ->
        Identifier.validate_search_path!("public, 'bad")
      end

      assert_raise ArgumentError, fn ->
        Identifier.validate_search_path!("public; DROP")
      end
    end
  end
end
