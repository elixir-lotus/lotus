defmodule Lotus.AI.StatementVisibilityTest do
  # The AI paths that ask the database about a statement check it for the
  # caller first, as running it would: nothing about a hidden table reaches
  # the model or the caller.
  use Lotus.AICase, async: false

  alias Lotus.AI.{QueryGenerator, QueryOptimizer}
  alias Lotus.Query.Statement

  setup do
    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{table: [deny: ["test_users"]]}
    end)

    :ok
  end

  defp text(messages) do
    messages
    |> Enum.flat_map(& &1.content)
    |> Enum.map_join("\n", &(&1.text || ""))
  end

  defp optimize(sql) do
    test = self()

    mock_text("[]", fn _model, context, _opts -> send(test, {:prompt, text(context)}) end)

    assert {:ok, _} =
             QueryOptimizer.suggest_optimizations("openai:gpt-4o",
               statement: Statement.new(sql),
               data_source: "postgres",
               api_key: "sk-test"
             )

    assert_received {:prompt, prompt}
    prompt
  end

  describe "suggest_optimizations/2" do
    test "sends no plan of a statement over a hidden table" do
      prompt = optimize("SELECT * FROM test_users WHERE id > 0")

      refute prompt =~ "Execution Plan"
      refute prompt =~ "Seq Scan"
    end

    test "sends the plan of a statement over visible tables" do
      assert optimize("SELECT * FROM test_posts WHERE id > 0") =~ "Execution Plan"
    end
  end

  describe "generate_statement/2" do
    test "a statement the model wrote over a hidden table is not taken" do
      mock_text("SELECT name FROM test_users")
      stub(Lotus.Source.Adapter, :validate_statement, fn _adapter, _statement, _opts -> :ok end)

      assert {:error, {:unable_to_generate, _}} =
               QueryGenerator.generate_statement("openai:gpt-4o",
                 prompt: "names",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end

    test "a statement the model wrote over visible tables is taken" do
      mock_text("SELECT title FROM test_posts")
      stub(Lotus.Source.Adapter, :validate_statement, fn _adapter, _statement, _opts -> :ok end)

      assert {:ok, %{content: "SELECT title FROM test_posts"}} =
               QueryGenerator.generate_statement("openai:gpt-4o",
                 prompt: "titles",
                 data_source: "postgres",
                 api_key: "sk-test"
               )
    end
  end
end
