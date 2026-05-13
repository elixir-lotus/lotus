defmodule Lotus.AI.InMemoryAdapterAITest do
  @moduledoc """
  Verifies `Lotus.AI` consumes `ai_context/1` from a non-SQL adapter —
  per-feature capability gates, prompt composition, and generation flow.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Lotus.AI
  alias Lotus.AI.Prompts.QueryGeneration
  alias Lotus.Config
  alias Lotus.Source
  alias Lotus.Source.Adapter
  alias Lotus.Test.InMemoryAdapter

  @source_name "mem"

  setup do
    prev_sources = Application.get_env(:lotus, :data_sources)
    prev_default = Application.get_env(:lotus, :default_source)
    prev_adapters = Application.get_env(:lotus, :source_adapters)
    prev_trusted = Application.get_env(:lotus, :trusted_source_adapters)

    dataset =
      InMemoryAdapter.dataset(
        tables: %{
          "users" => %{
            columns: ["id", "name"],
            rows: [[1, "Alice"]]
          }
        }
      )

    Application.put_env(:lotus, :data_sources, %{
      @source_name => dataset,
      "postgres" => Lotus.Test.Repo
    })

    Application.put_env(:lotus, :source_adapters, [InMemoryAdapter])
    Application.put_env(:lotus, :default_source, "postgres")
    Application.put_env(:lotus, :trusted_source_adapters, [InMemoryAdapter])

    Config.reload!()

    on_exit(fn ->
      restore_env(:data_sources, prev_sources)
      restore_env(:default_source, prev_default)
      restore_env(:source_adapters, prev_adapters)
      restore_env(:trusted_source_adapters, prev_trusted)
      Application.delete_env(:lotus, :ai)
      Config.reload!()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:lotus, key)
  defp restore_env(key, value), do: Application.put_env(:lotus, key, value)

  describe "Lotus.AI.supports?/2 and unsupported_reason/2 for the in-memory adapter" do
    test "generation and explanation are supported" do
      assert AI.supports?(@source_name, :generation)
      assert AI.supports?(@source_name, :explanation)
      assert is_nil(AI.unsupported_reason(@source_name, :generation))
      assert is_nil(AI.unsupported_reason(@source_name, :explanation))
    end

    test "optimization is declared unsupported with an adapter-provided reason" do
      refute AI.supports?(@source_name, :optimization)
      reason = AI.unsupported_reason(@source_name, :optimization)
      assert is_binary(reason)
      assert reason =~ "no execution plan"
    end
  end

  describe "Adapter.ai_context/1 pass-through" do
    test "returns language, example_query, and syntax_notes for a trusted adapter" do
      adapter = Source.get_source!(@source_name)
      assert {:ok, ctx} = Adapter.ai_context(adapter)

      assert ctx.language == "lotus:in_memory"
      assert ctx.example_query =~ ~s|from: "users"|
      assert ctx.syntax_notes =~ "Statements are Elixir maps"
      assert is_list(ctx.error_patterns)
      assert Enum.any?(ctx.error_patterns, fn %{pattern: p} -> Regex.source(p) =~ "not found" end)
    end

    test "untrusted adapter loses free-form fields" do
      Application.put_env(:lotus, :trusted_source_adapters, [])
      Config.reload!()

      adapter = Source.get_source!(@source_name)
      assert {:ok, ctx} = Adapter.ai_context(adapter)

      assert ctx.language == "lotus:in_memory"
      assert ctx.example_query == ""
      assert ctx.syntax_notes == ""
      assert ctx.error_patterns == []
    end
  end

  describe "QueryGeneration prompt composition" do
    test "prompt includes the adapter's language, example_query, and syntax_notes" do
      adapter = Source.get_source!(@source_name)
      {:ok, ctx} = Adapter.ai_context(adapter)

      prompt = QueryGeneration.system_prompt(ctx, ["users"], read_only: true)

      assert prompt =~ "lotus:in_memory"
      assert prompt =~ ~s|from: "users"|
      assert prompt =~ "Statements are Elixir maps"
    end
  end

  describe "generate_query_with_context/1 feature gating" do
    setup do
      Mimic.copy(ReqLLM)
      :ok
    end

    test "generate_query_with_context receives a prompt built from the adapter's ai_context" do
      Application.put_env(:lotus, :ai,
        enabled: true,
        api_key: "sk-test",
        model: "openai:gpt-4o"
      )

      Config.reload!()

      test_pid = self()

      expect(ReqLLM, :generate_text, fn _model, messages, _opts ->
        # Capture the rendered system prompt so we can assert the adapter's
        # ai_context fields made it through the pipeline. `messages` is a
        # list of `%ReqLLM.Message{}`.
        system_text =
          Enum.find_value(messages, fn msg ->
            case msg do
              %{role: :system, content: [%{text: t} | _]} -> t
              %{role: :system, content: t} when is_binary(t) -> t
              _ -> nil
            end
          end)

        send(test_pid, {:system_prompt, system_text})

        message = ReqLLM.Context.assistant("```sql\n%{from: \"users\"}\n```")

        {:ok,
         %ReqLLM.Response{
           id: "mock-1",
           message: message,
           context: ReqLLM.Context.new([message]),
           finish_reason: :stop,
           usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
           model: "openai:gpt-4o"
         }}
      end)

      assert {:ok, result} =
               AI.generate_query_with_context(
                 prompt: "list users",
                 data_source: @source_name
               )

      assert result.model == "openai:gpt-4o"
      assert_received {:system_prompt, prompt}
      assert prompt =~ "lotus:in_memory"
      assert prompt =~ ~s|from: "users"|
      assert prompt =~ "Statements are Elixir maps"
    end

    test "suggest_optimizations is blocked with the adapter-declared reason" do
      Application.put_env(:lotus, :ai,
        enabled: true,
        api_key: "sk-test",
        model: "openai:gpt-4o"
      )

      Config.reload!()

      statement = %Lotus.Query.Statement{text: %{from: "users"}}

      assert {:error, {:ai_feature_unsupported, :optimization, reason}} =
               AI.suggest_optimizations(statement: statement, data_source: @source_name)

      assert reason =~ "no execution plan"
    end
  end
end
