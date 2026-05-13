defmodule Lotus.AI.QueryGeneratorTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.QueryGenerator

  describe "generate_sql/2" do
    setup do
      setup_mocks()

      stub(Lotus.Source, :source_type, fn _ -> :postgres end)
      stub(Lotus.Schema, :list_tables, fn _ -> {:ok, table_list()} end)

      :ok
    end

    test "generates SQL successfully" do
      mock_successful_generation()

      assert {:ok, response} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Show active users",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert response.content =~ "SELECT * FROM users"
      assert response.model == "openai:gpt-4o"
      assert response.usage.prompt_tokens == 150
      assert response.usage.completion_tokens == 50
      assert response.usage.total_tokens == 200
    end

    test "passes correct model string to ReqLLM" do
      mock_with_assertion(fn model, _context, _opts ->
        assert model == "openai:gpt-3.5-turbo"
      end)

      assert {:ok, _} =
               QueryGenerator.generate_sql("openai:gpt-3.5-turbo",
                 prompt: "Test",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "passes temperature in opts" do
      mock_with_assertion(fn _model, _context, opts ->
        assert opts[:temperature] == 0.1
      end)

      assert {:ok, _} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Test",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "passes API key in opts" do
      mock_with_assertion(fn _model, _context, opts ->
        assert opts[:api_key] == "sk-test123"
      end)

      assert {:ok, _} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Test",
                 data_source: "postgres",
                 api_key: "sk-test123"
               )
    end

    test "includes schema query tools" do
      mock_with_assertion(fn _model, _context, opts ->
        tools = opts[:tools]
        assert length(tools) == 5

        tool_names = Enum.map(tools, & &1.name)
        assert "list_schemas" in tool_names
        assert "list_tables" in tool_names
        assert "describe_table" in tool_names
        assert "get_column_values" in tool_names
        assert "validate_sql" in tool_names
      end)

      assert {:ok, _} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Test",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "works with anthropic model string" do
      mock_plain_sql()

      assert {:ok, response} =
               QueryGenerator.generate_sql("anthropic:claude-opus-4",
                 prompt: "Count users",
                 data_source: "postgres",
                 api_key: "sk-ant-test"
               )

      assert response.content == "SELECT COUNT(*) FROM users WHERE status = 'active'"
      assert response.model == "anthropic:claude-opus-4"
      assert response.usage.prompt_tokens == 120
      assert response.usage.completion_tokens == 30
      assert response.usage.total_tokens == 150
    end

    test "works with gemini model string" do
      mock_complex_sql()

      assert {:ok, response} =
               QueryGenerator.generate_sql("google:gemini-2.0-flash-exp",
                 prompt: "Top products by revenue",
                 data_source: "postgres",
                 api_key: "AIzaSyTest"
               )

      assert response.content =~ "SELECT"
      assert response.content =~ "JOIN"
      assert response.model == "google:gemini-2.0-flash-exp"
      assert response.usage.prompt_tokens == 200
      assert response.usage.completion_tokens == 80
      assert response.usage.total_tokens == 280
    end

    test "returns structured error when LLM refuses" do
      mock_unable_to_generate()

      assert {:error, {:unable_to_generate, reason}} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "What's the weather?",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert reason == "This is a weather question, not a database query"
    end

    test "returns wrapped error when API fails" do
      mock_api_error("Invalid API key")

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Test",
                 data_source: "postgres",
                 api_key: "sk-invalid"
               )
    end

    test "returns wrapped error when request times out" do
      mock_timeout()

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Test",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "extracts and returns variables from LLM response" do
      mock_sql_with_variables()

      assert {:ok, response} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Show orders with a status dropdown",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert response.content =~ "SELECT * FROM orders"
      assert length(response.variables) == 1

      variable = hd(response.variables)
      assert variable["name"] == "status"
      assert variable["type"] == "text"
      assert variable["widget"] == "select"
    end

    test "returns empty variables for SQL-only response" do
      mock_successful_generation()

      assert {:ok, response} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Show active users",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert response.variables == []
    end

    test "extracts plain SQL without markdown" do
      mock_plain_sql()

      assert {:ok, response} =
               QueryGenerator.generate_sql("openai:gpt-4o",
                 prompt: "Count users",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert response.content == "SELECT COUNT(*) FROM users WHERE status = 'active'"
    end
  end
end
