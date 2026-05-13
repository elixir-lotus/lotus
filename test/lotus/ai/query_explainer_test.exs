defmodule Lotus.AI.QueryExplainerTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.QueryExplainer

  describe "explain_query/2" do
    setup do
      setup_mocks()

      Mimic.copy(Lotus.Config)

      stub(Lotus.Source, :source_type, fn _ -> :postgres end)
      stub(Lotus.Config, :get_data_source!, fn "postgres" -> Lotus.Test.Repo end)

      :ok
    end

    test "returns explanation for a full query" do
      mock_explanation()

      assert {:ok, result} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM orders WHERE created_at > '2024-01-01'",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert result.explanation =~ "orders"
      assert result.model == "openai:gpt-4o"
      assert result.usage.prompt_tokens == 300
      assert result.usage.completion_tokens == 100
      assert result.usage.total_tokens == 400
    end

    test "returns explanation for a fragment" do
      mock_fragment_explanation()

      assert {:ok, result} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql:
                   "SELECT d.name FROM departments d LEFT JOIN employees e ON e.department_id = d.id",
                 fragment: "LEFT JOIN employees e ON e.department_id = d.id",
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert result.explanation =~ "employees"
    end

    test "sends fragment prompt when fragment is provided" do
      mock_with_assertion(fn _model, messages, _opts ->
        user_message = Enum.find(messages, &(&1.role == :user))
        content_text = Enum.map_join(user_message.content, & &1.text)
        assert content_text =~ "Selected Fragment"
        assert content_text =~ "Full Query (for context)"
      end)

      assert {:ok, _} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM orders JOIN users ON users.id = orders.user_id",
                 fragment: "JOIN users ON users.id = orders.user_id",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "sends full query prompt when no fragment" do
      mock_with_assertion(fn _model, messages, _opts ->
        user_message = Enum.find(messages, &(&1.role == :user))
        content_text = Enum.map_join(user_message.content, & &1.text)
        assert content_text =~ "Explain what this SQL query does"
        refute content_text =~ "Selected Fragment"
      end)

      assert {:ok, _} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM orders",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "passes correct model string to ReqLLM" do
      mock_with_assertion(fn model, _context, _opts ->
        assert model == "anthropic:claude-opus-4"
      end)

      assert {:ok, _} =
               QueryExplainer.explain_query("anthropic:claude-opus-4",
                 sql: "SELECT * FROM orders",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "includes describe_table tool" do
      mock_with_assertion(fn _model, _context, opts ->
        tools = opts[:tools]
        assert length(tools) == 1

        tool_names = Enum.map(tools, & &1.name)
        assert "describe_table" in tool_names
      end)

      assert {:ok, _} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM orders",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "preserves Lotus variable syntax in the prompt sent to LLM" do
      original_sql =
        "SELECT * FROM users WHERE id = {{user_id}} [[AND status = {{status}}]]"

      mock_with_assertion(fn _model, messages, _opts ->
        user_message = Enum.find(messages, &(&1.role == :user))
        content_text = Enum.map_join(user_message.content, & &1.text)
        assert content_text =~ "{{user_id}}"
        assert content_text =~ "[[AND status"
        assert content_text =~ "{{status}}"
      end)

      assert {:ok, _} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: original_sql,
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "sends Lotus syntax fragment with full query context" do
      mock_with_assertion(fn _model, messages, _opts ->
        user_message = Enum.find(messages, &(&1.role == :user))
        content_text = Enum.map_join(user_message.content, & &1.text)
        assert content_text =~ "Selected Fragment"
        assert content_text =~ "[[AND status = {{status}}]]"
        assert content_text =~ "Full Query (for context)"
      end)

      assert {:ok, _} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM users WHERE 1=1 [[AND status = {{status}}]]",
                 fragment: "[[AND status = {{status}}]]",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "returns wrapped error when API fails" do
      mock_api_error("Invalid API key")

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM orders",
                 data_source: "postgres",
                 api_key: "sk-invalid"
               )
    end

    test "returns wrapped error when request times out" do
      mock_timeout()

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 sql: "SELECT * FROM orders",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end
  end
end
