defmodule Lotus.AI.Actions.ListSchemasTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.ListSchemas

  describe "run/2" do
    test "returns list of schemas" do
      stub(Lotus.Schema, :list_schemas, fn _source, _opts ->
        {:ok, ["public", "reporting", "analytics"]}
      end)

      assert {:ok, result} = ListSchemas.run(%{data_source: "postgres"}, %{})
      assert result.schemas == ["public", "reporting", "analytics"]
    end

    test "returns error when schema introspection fails" do
      stub(Lotus.Schema, :list_schemas, fn _source, _opts ->
        {:error, "Connection failed"}
      end)

      assert {:error, "Connection failed"} = ListSchemas.run(%{data_source: "postgres"}, %{})
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and schema" do
      assert ListSchemas.name() == "list_schemas"
      assert ListSchemas.description() =~ "schemas"
      assert Keyword.has_key?(ListSchemas.schema(), :data_source)
    end
  end
end
