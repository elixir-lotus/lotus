defmodule Lotus.AI.Actions.ListTablesTest do
  use Lotus.AICase, async: true

  import Lotus.AIFixtures

  alias Lotus.AI.Actions.ListTables

  describe "run/2" do
    test "returns schema-qualified table names" do
      stub(Lotus.Schema, :list_tables, fn _source, _opts ->
        {:ok, table_list()}
      end)

      assert {:ok, result} = ListTables.run(%{data_source: "postgres"}, %{})

      assert result.tables == [
               "public.users",
               "public.posts",
               "public.comments",
               "analytics.events"
             ]
    end

    test "returns plain table names for schema-less databases" do
      stub(Lotus.Schema, :list_tables, fn _source, _opts ->
        {:ok, sqlite_table_list()}
      end)

      assert {:ok, result} = ListTables.run(%{data_source: "sqlite"}, %{})
      assert result.tables == ["users", "posts", "comments"]
    end

    test "returns error when listing fails" do
      stub(Lotus.Schema, :list_tables, fn _source, _opts ->
        {:error, "Connection failed"}
      end)

      assert {:error, "Connection failed"} = ListTables.run(%{data_source: "postgres"}, %{})
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and schema" do
      assert ListTables.name() == "list_tables"
      assert ListTables.description() =~ "tables"
      assert Keyword.has_key?(ListTables.schema(), :data_source)
    end
  end
end
