defmodule Lotus.AI.ToolTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.{DescribeTable, ListSchemas, ListTables}
  alias Lotus.AI.Tool

  describe "from_action/2" do
    test "converts an action module to a ReqLLM tool" do
      stub(Lotus.Schema, :list_schemas, fn _source ->
        {:ok, ["public", "reporting"]}
      end)

      tool = Tool.from_action(ListSchemas, bind: %{data_source: "postgres"})

      assert tool.name == "list_schemas"
      assert tool.description =~ "schemas"
      assert is_function(tool.callback, 1)
    end

    test "strips bound params from the parameter schema" do
      tool = Tool.from_action(DescribeTable, bind: %{data_source: "postgres"})

      # data_source should not be exposed to the LLM
      refute Map.has_key?(tool.parameter_schema["properties"], "data_source")
      refute "data_source" in (tool.parameter_schema["required"] || [])

      # table_name should still be exposed
      assert Map.has_key?(tool.parameter_schema["properties"], "table_name")
      assert "table_name" in tool.parameter_schema["required"]
    end

    test "exposes all params when no bind is provided" do
      tool = Tool.from_action(DescribeTable)

      assert Map.has_key?(tool.parameter_schema["properties"], "data_source")
      assert Map.has_key?(tool.parameter_schema["properties"], "table_name")
    end

    test "callback injects bound params and calls action" do
      stub(Lotus.Schema, :list_tables, fn source ->
        assert source == "postgres"
        {:ok, [{"public", "users"}]}
      end)

      tool = Tool.from_action(ListTables, bind: %{data_source: "postgres"})

      assert {:ok, json} = tool.callback.(%{})
      assert {:ok, decoded} = Lotus.JSON.decode(json)
      assert decoded["tables"] == ["public.users"]
    end

    test "callback handles LLM args with string keys" do
      stub(Lotus.Schema, :describe_table, fn _source, _table ->
        {:ok, [%{name: "id", type: "integer", nullable: false, primary_key: true}]}
      end)

      tool = Tool.from_action(DescribeTable, bind: %{data_source: "postgres"})

      assert {:ok, json} = tool.callback.(%{"table_name" => "users"})
      assert {:ok, decoded} = Lotus.JSON.decode(json)
      assert decoded["table"] == "users"
    end

    test "callback returns JSON error on action failure" do
      stub(Lotus.Schema, :list_schemas, fn _source ->
        {:error, "Connection refused"}
      end)

      tool = Tool.from_action(ListSchemas, bind: %{data_source: "postgres"})

      assert {:ok, json} = tool.callback.(%{})
      assert {:ok, decoded} = Lotus.JSON.decode(json)
      assert decoded["error"] =~ "Connection refused"
    end

    test "callback handles unknown LLM parameter keys gracefully" do
      stub(Lotus.Schema, :list_schemas, fn _source ->
        {:ok, ["public"]}
      end)

      tool = Tool.from_action(ListSchemas, bind: %{data_source: "postgres"})

      # LLM sends a hallucinated parameter — should not crash
      assert {:ok, _json} = tool.callback.(%{"hallucinated_param" => "value"})
    end
  end
end
