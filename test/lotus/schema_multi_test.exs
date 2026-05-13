defmodule Lotus.SchemaMultiTest do
  use Lotus.Case, async: true

  @moduletag :postgres

  describe "schema-aware table listing" do
    test "list_tables with default schema returns public tables only" do
      {:ok, tables} = Lotus.list_tables("postgres")

      assert {"public", "test_users"} in tables
      assert {"public", "test_posts"} in tables
      refute {"reporting", "customers"} in tables
      refute {"reporting", "orders"} in tables
    end

    test "list_tables with explicit schema finds tables in that schema" do
      {:ok, tables} = Lotus.list_tables("postgres", schema: "reporting")

      assert {"reporting", "customers"} in tables
      assert {"reporting", "orders"} in tables
      refute {"public", "test_users"} in tables
    end

    test "list_tables with search_path finds tables across multiple schemas" do
      {:ok, tables} = Lotus.list_tables("postgres", search_path: "reporting, public")

      assert {"reporting", "customers"} in tables
      assert {"reporting", "orders"} in tables
      assert {"public", "test_users"} in tables
      assert {"public", "test_posts"} in tables
    end

    test "list_tables with explicit schemas list finds tables across schemas" do
      {:ok, tables} = Lotus.list_tables("postgres", schemas: ["reporting", "public"])

      assert {"reporting", "customers"} in tables
      assert {"public", "test_users"} in tables
    end

    test "list_relations returns schema information" do
      {:ok, relations} = Lotus.list_relations("postgres", search_path: "reporting, public")

      assert {"reporting", "customers"} in relations
      assert {"reporting", "orders"} in relations
      assert {"public", "test_users"} in relations
      assert {"public", "test_posts"} in relations
    end
  end

  describe "schema-aware table schema inspection" do
    test "describe_table resolves table using search_path" do
      {:ok, schema} =
        Lotus.describe_table("postgres", "customers", search_path: "reporting, public")

      assert is_list(schema)
      refute Enum.empty?(schema)

      column_names = Enum.map(schema, & &1.name)
      assert "name" in column_names
      assert "email" in column_names
    end

    test "describe_table with explicit schema works" do
      {:ok, schema} = Lotus.describe_table("postgres", "customers", schema: "reporting")

      assert is_list(schema)
      column_names = Enum.map(schema, & &1.name)
      assert "name" in column_names
      assert "email" in column_names
    end

    test "describe_table fails when table not in specified schema" do
      {:error, msg} = Lotus.describe_table("postgres", "test_users", schema: "reporting")

      assert msg =~ "not found in schemas"
    end

    test "describe_table defaults to public schema when no opts given" do
      {:ok, schema} = Lotus.describe_table("postgres", "test_users")

      assert is_list(schema)
      column_names = Enum.map(schema, & &1.name)
      assert "name" in column_names
      assert "email" in column_names
    end
  end

  describe "schema-aware table stats" do
    test "get_table_stats resolves table using search_path" do
      {:ok, stats} =
        Lotus.get_table_stats("postgres", "customers", search_path: "reporting, public")

      assert %{row_count: 0} = stats
    end

    test "get_table_stats with explicit schema works" do
      {:ok, stats} = Lotus.get_table_stats("postgres", "customers", schema: "reporting")

      assert %{row_count: 0} = stats
    end

    test "get_table_stats fails when table not in specified schema" do
      {:error, msg} = Lotus.get_table_stats("postgres", "test_users", schema: "reporting")

      assert msg =~ "not found in schemas"
    end
  end

  describe "edge cases and error handling" do
    test "empty search_path defaults to public" do
      {:ok, tables} = Lotus.list_tables("postgres", search_path: "")

      assert {"public", "test_users"} in tables
      refute {"reporting", "customers"} in tables
    end

    test "non-existent schema returns empty results" do
      {:ok, tables} = Lotus.list_tables("postgres", schema: "nonexistent")

      assert tables == []
    end

    test "search_path with non-existent schema ignores it" do
      {:ok, tables} = Lotus.list_tables("postgres", search_path: "nonexistent, reporting")

      assert {"reporting", "customers"} in tables
      refute {"public", "test_users"} in tables
    end
  end
end
