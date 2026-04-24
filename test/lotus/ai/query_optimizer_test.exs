defmodule Lotus.AI.QueryOptimizerTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.QueryOptimizer
  alias Lotus.Query.Statement

  describe "suggest_optimizations/2" do
    setup do
      setup_mocks()

      Mimic.copy(Lotus.Source)
      Mimic.copy(Lotus.Source.Adapter)

      stub(Lotus.Source, :get_source!, fn "postgres" ->
        %Lotus.Source.Adapter{
          name: "postgres",
          module: Lotus.Source.Adapters.Postgres,
          state: Lotus.Test.Repo,
          source_type: :postgres
        }
      end)

      stub(Lotus.Source.Adapter, :query_plan, fn _adapter, _sql, _params, _opts ->
        {:ok, postgres_explain_plan()}
      end)

      :ok
    end

    test "returns optimization suggestions" do
      mock_optimization_suggestions()

      assert {:ok, result} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT * FROM orders WHERE created_at > '2024-01-01'"),
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert length(result.suggestions) == 2
      assert result.model == "openai:gpt-4o"
      assert result.usage.prompt_tokens == 500
      assert result.usage.completion_tokens == 200
      assert result.usage.total_tokens == 700

      [first, second] = result.suggestions
      assert first["type"] == "index"
      assert first["impact"] == "high"
      assert first["title"] =~ "index"
      assert first["suggestion"] =~ "CREATE INDEX"

      assert second["type"] == "rewrite"
      assert second["impact"] == "medium"
    end

    test "returns empty suggestions for well-optimized queries" do
      mock_no_optimizations()

      assert {:ok, result} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT id, name FROM users WHERE id = 1"),
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert result.suggestions == []
    end

    test "works when execution plan is unavailable" do
      stub(Lotus.Source.Adapter, :query_plan, fn _adapter, _sql, _params, _opts ->
        {:error, "permission denied"}
      end)

      mock_optimization_suggestions()

      assert {:ok, result} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT * FROM orders"),
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert is_list(result.suggestions)
    end

    test "passes correct model string to ReqLLM" do
      mock_with_assertion(fn model, _context, _opts ->
        assert model == "anthropic:claude-opus-4"
      end)

      assert {:ok, _} =
               QueryOptimizer.suggest_optimizations("anthropic:claude-opus-4",
                 statement: Statement.new("SELECT * FROM orders"),
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
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT * FROM orders"),
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "returns wrapped error when API fails" do
      mock_api_error("Invalid API key")

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT * FROM orders"),
                 data_source: "postgres",
                 api_key: "sk-invalid"
               )
    end

    test "returns wrapped error when request times out" do
      mock_timeout()

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT * FROM orders"),
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "sanitizes Lotus variable syntax before calling query_plan" do
      expect(Lotus.Source.Adapter, :query_plan, fn _adapter, sql, _params, _opts ->
        refute sql =~ "{{"
        refute sql =~ "}}"
        assert sql =~ "NULL"
        {:ok, postgres_explain_plan()}
      end)

      mock_optimization_suggestions()

      assert {:ok, _} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement:
                   Statement.new(
                     "SELECT * FROM users WHERE id = {{user_id}} AND status = {{status}}"
                   ),
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "sanitizes optional clause brackets before calling query_plan" do
      expect(Lotus.Source.Adapter, :query_plan, fn _adapter, sql, _params, _opts ->
        refute sql =~ "[["
        refute sql =~ "]]"
        assert sql =~ "AND name ILIKE"
        {:ok, postgres_explain_plan()}
      end)

      mock_optimization_suggestions()

      sql = """
      SELECT id, name FROM users
      WHERE 1=1
      [[AND name ILIKE {{name}} || '%']]
      ORDER BY id
      """

      assert {:ok, _} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new(sql),
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "sends original SQL with Lotus syntax to AI prompt" do
      stub(Lotus.Source.Adapter, :query_plan, fn _adapter, _sql, _params, _opts ->
        {:ok, postgres_explain_plan()}
      end)

      original_sql = "SELECT * FROM users WHERE id = {{user_id}} [[AND status = {{status}}]]"

      mock_with_assertion(fn _model, messages, _opts ->
        user_message = Enum.find(messages, &(&1.role == :user))
        content_text = Enum.map_join(user_message.content, & &1.text)
        assert content_text =~ "{{user_id}}"
        assert content_text =~ "[[AND status"
      end)

      assert {:ok, _} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new(original_sql),
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end
  end
end
