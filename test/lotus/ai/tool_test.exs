defmodule Lotus.AI.ToolTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.{DescribeTable, ListSchemas, ListTables}
  alias Lotus.AI.Tool

  describe "from_action/2" do
    test "converts an action module to a ReqLLM tool" do
      stub(Lotus.Schema, :list_schemas, fn _source, _opts ->
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
      stub(Lotus.Schema, :list_tables, fn source, _opts ->
        assert source == "postgres"
        {:ok, [{"public", "users"}]}
      end)

      tool = Tool.from_action(ListTables, bind: %{data_source: "postgres"})

      assert {:ok, json} = tool.callback.(%{})
      assert {:ok, decoded} = Lotus.JSON.decode(json)
      assert decoded["tables"] == ["public.users"]
    end

    test "callback handles LLM args with string keys" do
      stub(Lotus.Schema, :describe_table, fn _source, _table, _opts ->
        {:ok, [%{name: "id", type: "integer", nullable: false, primary_key: true}]}
      end)

      tool = Tool.from_action(DescribeTable, bind: %{data_source: "postgres"})

      assert {:ok, json} = tool.callback.(%{"table_name" => "users"})
      assert {:ok, decoded} = Lotus.JSON.decode(json)
      assert decoded["table"] == "users"
    end

    test "callback returns JSON error on action failure" do
      stub(Lotus.Schema, :list_schemas, fn _source, _opts ->
        {:error, "Connection refused"}
      end)

      tool = Tool.from_action(ListSchemas, bind: %{data_source: "postgres"})

      assert {:ok, json} = tool.callback.(%{})
      assert {:ok, decoded} = Lotus.JSON.decode(json)
      assert decoded["error"] =~ "Connection refused"
    end

    test "callback handles unknown LLM parameter keys gracefully" do
      stub(Lotus.Schema, :list_schemas, fn _source, _opts ->
        {:ok, ["public"]}
      end)

      tool = Tool.from_action(ListSchemas, bind: %{data_source: "postgres"})

      # LLM sends a hallucinated parameter — should not crash
      assert {:ok, _json} = tool.callback.(%{"hallucinated_param" => "value"})
    end
  end

  describe "run/4 with :on_text" do
    test "streams the round and hands on each piece of text" do
      answer = ReqLLM.Context.assistant("Counts users.")

      response = %ReqLLM.Response{
        id: "mock",
        message: answer,
        context: ReqLLM.Context.new([answer]),
        finish_reason: :stop,
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
        model: "gpt-4o"
      }

      reject(&ReqLLM.generate_text/3)
      stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, :stream} end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :stream, opts ->
        Enum.each(["Counts ", "users."], opts[:on_result])
        {:ok, response}
      end)

      test_pid = self()
      context = ReqLLM.Context.new([ReqLLM.Context.user("Explain")])

      assert {:ok, %ReqLLM.Response{}} =
               Tool.run("openai:gpt-4o", context, [],
                 api_key: "sk-test",
                 on_text: &send(test_pid, {:text, &1})
               )

      assert_received {:text, "Counts "}
      assert_received {:text, "users."}
    end
  end

  describe "run/4 with :on_round" do
    # A round that asks for a tool, as many times as the loop goes on.
    defp asks_for_a_tool do
      call = ReqLLM.ToolCall.new("call-1", "list_schemas", ~s({"data_source": "postgres"}))
      message = ReqLLM.Context.assistant("", tool_calls: [call])

      %ReqLLM.Response{
        id: "mock",
        message: message,
        context: ReqLLM.Context.new([message]),
        finish_reason: :tool_calls,
        usage: %{input_tokens: 40, output_tokens: 10, total_tokens: 50},
        model: "gpt-4o"
      }
    end

    test "is told each round's usage so far, and halts the loop" do
      stub(ReqLLM, :generate_text, fn _model, _messages, _opts -> {:ok, asks_for_a_tool()} end)
      stub(Lotus.Schema, :list_schemas, fn _source, _opts -> {:ok, ["public"]} end)

      test_pid = self()
      tool = Tool.from_action(Lotus.AI.Actions.ListSchemas)
      context = ReqLLM.Context.new([ReqLLM.Context.user("Why?")])

      on_round = fn round ->
        send(test_pid, {:round, round.iteration, round.usage.total_tokens, round.tool_calls})
        if round.usage.total_tokens >= 100, do: :halt, else: :cont
      end

      assert {:ok, %ReqLLM.Response{}} =
               Tool.run("openai:gpt-4o", context, [tool], api_key: "sk-test", on_round: on_round)

      assert_received {:round, 1, 50, []}
      assert_received {:round, 2, 100, ["list_schemas"]}
      refute_received {:round, 3, _tokens, _calls}
    end

    test "a callback that raises does not stop the loop" do
      answer = ReqLLM.Context.assistant("Done.")

      stub(ReqLLM, :generate_text, fn _model, _messages, _opts ->
        {:ok,
         %ReqLLM.Response{
           id: "mock",
           message: answer,
           context: ReqLLM.Context.new([answer]),
           finish_reason: :stop,
           usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
           model: "gpt-4o"
         }}
      end)

      context = ReqLLM.Context.new([ReqLLM.Context.user("Why?")])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %ReqLLM.Response{}} =
                   Tool.run("openai:gpt-4o", context, [],
                     api_key: "sk-test",
                     on_round: fn _round -> raise "boom" end
                   )
        end)

      assert log =~ "on_round raised: boom"
    end
  end
end
