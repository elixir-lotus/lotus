defmodule Lotus.AITest do
  use Lotus.AICase, async: true

  alias Lotus.AI
  alias Lotus.Query.Statement

  describe "enabled?/0" do
    test "returns false when AI not configured" do
      refute AI.enabled?()
    end

    test "returns false when AI disabled" do
      set_ai_config(enabled: false)

      refute AI.enabled?()
    end

    test "returns false when API key missing" do
      set_ai_config(enabled: true)

      refute AI.enabled?()
    end

    test "returns true when properly configured" do
      set_ai_config(enabled: true, api_key: "sk-test123")

      assert AI.enabled?()
    end
  end

  describe "model/0" do
    test "returns error when not configured" do
      assert {:error, :not_configured} = AI.model()
    end

    test "returns default model when not specified" do
      set_ai_config(enabled: true, api_key: "sk-test")

      assert {:ok, "openai:gpt-4o"} = AI.model()
    end

    test "returns configured model" do
      set_ai_config(enabled: true, api_key: "sk-test", model: "anthropic:claude-opus-4")

      assert {:ok, "anthropic:claude-opus-4"} = AI.model()
    end
  end

  describe "generate_query/1" do
    setup do
      setup_mocks()

      # Mock schema introspection
      stub(Lotus.Source, :source_type, fn _ -> :postgres end)
      stub(Lotus.Schema, :list_tables, fn _ -> {:ok, table_list()} end)

      set_ai_config(enabled: true, api_key: "sk-test")

      :ok
    end

    test "generates SQL successfully" do
      mock_successful_generation()

      assert {:ok, result} =
               AI.generate_query(
                 prompt: "Show active users from last 30 days",
                 data_source: "postgres"
               )

      assert result.sql =~ "SELECT * FROM users"
      assert result.sql =~ "created_at >= NOW()"
      assert result.variables == []
      assert result.model == "openai:gpt-4o"
      assert result.usage.total_tokens == 200
    end

    test "returns variables when LLM generates them" do
      mock_sql_with_variables()

      assert {:ok, result} =
               AI.generate_query(
                 prompt: "Show orders with a status dropdown",
                 data_source: "postgres"
               )

      assert result.sql =~ "SELECT * FROM orders"
      assert length(result.variables) == 1
      assert hd(result.variables)["name"] == "status"
    end

    test "handles plain SQL without markdown" do
      mock_plain_sql()

      assert {:ok, result} =
               AI.generate_query(
                 prompt: "Count active users",
                 data_source: "postgres"
               )

      assert result.sql == "SELECT COUNT(*) FROM users WHERE status = 'active'"
    end

    test "handles complex SQL with JOINs" do
      mock_complex_sql()

      assert {:ok, result} =
               AI.generate_query(
                 prompt: "Top products by revenue",
                 data_source: "postgres"
               )

      assert result.sql =~ "SELECT"
      assert result.sql =~ "JOIN"
      assert result.sql =~ "GROUP BY"
    end

    test "returns structured error when AI not configured" do
      Application.delete_env(:lotus, :ai)
      Lotus.Config.reload!()
      on_exit(fn -> Lotus.Config.reload!() end)

      assert {:error, :not_configured} =
               AI.generate_query(
                 prompt: "test",
                 data_source: "postgres"
               )
    end

    test "returns structured error when API key missing" do
      set_ai_config(enabled: true)

      assert {:error, :api_key_not_configured} =
               AI.generate_query(
                 prompt: "test",
                 data_source: "postgres"
               )
    end

    test "returns structured error when LLM refuses to generate" do
      mock_unable_to_generate()

      assert {:error, {:unable_to_generate, reason}} =
               AI.generate_query(
                 prompt: "What's the weather?",
                 data_source: "postgres"
               )

      assert reason == "This is a weather question, not a database query"
    end

    test "returns wrapped error when API fails" do
      mock_api_error("Rate limit exceeded")

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               AI.generate_query(
                 prompt: "test",
                 data_source: "postgres"
               )
    end

    test "returns wrapped error when request times out" do
      mock_timeout()

      assert {:error, %Lotus.AI.Error.ServiceError{}} =
               AI.generate_query(
                 prompt: "test",
                 data_source: "postgres"
               )
    end

    test "resolves {:system, env_var} API key" do
      System.put_env("TEST_AI_KEY", "sk-from-env")
      set_ai_config(enabled: true, api_key: {:system, "TEST_AI_KEY"})

      mock_successful_generation()

      assert {:ok, _result} =
               AI.generate_query(
                 prompt: "test",
                 data_source: "postgres"
               )

      System.delete_env("TEST_AI_KEY")
    end
  end

  describe "generate_query_with_context/1" do
    setup do
      setup_mocks()

      stub(Lotus.Source, :source_type, fn _ -> :postgres end)
      stub(Lotus.Schema, :list_tables, fn _ -> {:ok, table_list()} end)

      set_ai_config(enabled: true, api_key: "sk-test")

      :ok
    end

    test "returns variables in result map" do
      mock_sql_with_variables()

      assert {:ok, result} =
               AI.generate_query_with_context(
                 prompt: "Show orders with a status dropdown",
                 data_source: "postgres"
               )

      assert result.sql =~ "SELECT * FROM orders"
      assert length(result.variables) == 1
      assert hd(result.variables)["name"] == "status"
    end

    test "returns empty variables for SQL-only response" do
      mock_successful_generation()

      assert {:ok, result} =
               AI.generate_query_with_context(
                 prompt: "Show active users",
                 data_source: "postgres"
               )

      assert result.variables == []
    end
  end

  describe "supports?/2 and unsupported_reason/2" do
    setup do
      set_ai_config(enabled: true, api_key: "sk-test")

      Mimic.copy(Lotus.Source)
      Mimic.copy(Lotus.Source.Adapter)
      :ok
    end

    setup :set_mimic_from_context

    test "adapter declaring all capabilities true — supports?/2 returns true for each" do
      stub(Lotus.Source, :get_source!, fn "pg" ->
        %Lotus.Source.Adapter{
          name: "pg",
          module: Lotus.Source.Adapters.Postgres,
          state: nil,
          source_type: :postgres
        }
      end)

      stub(Lotus.Source.Adapter, :ai_context, fn _adapter ->
        {:ok, %{capabilities: %{generation: true, optimization: true, explanation: true}}}
      end)

      assert AI.supports?("pg", :generation) == true
      assert AI.supports?("pg", :optimization) == true
      assert AI.supports?("pg", :explanation) == true
      assert AI.unsupported_reason("pg", :generation) == nil
    end

    test "adapter declaring {false, reason} — supports?/2 false, reason surfaced" do
      stub(Lotus.Source, :get_source!, fn "ro" ->
        %Lotus.Source.Adapter{
          name: "ro",
          module: Lotus.Source.Adapters.Postgres,
          state: nil,
          source_type: :postgres
        }
      end)

      stub(Lotus.Source.Adapter, :ai_context, fn _adapter ->
        {:ok,
         %{
           capabilities: %{
             generation: {false, "This data source is read-only and production-only"},
             optimization: true,
             explanation: true
           }
         }}
      end)

      assert AI.supports?("ro", :generation) == false
      assert AI.supports?("ro", :optimization) == true

      assert AI.unsupported_reason("ro", :generation) ==
               "This data source is read-only and production-only"

      assert AI.unsupported_reason("ro", :optimization) == nil
    end

    test "adapter returning {:error, _} from ai_context/1 — all features unsupported" do
      stub(Lotus.Source, :get_source!, fn "opted_out" ->
        %Lotus.Source.Adapter{
          name: "opted_out",
          module: Lotus.Source.Adapters.Postgres,
          state: nil,
          source_type: :postgres
        }
      end)

      stub(Lotus.Source.Adapter, :ai_context, fn _adapter -> {:error, :ai_not_supported} end)

      assert AI.supports?("opted_out", :generation) == false
      assert AI.supports?("opted_out", :optimization) == false
      assert AI.supports?("opted_out", :explanation) == false

      assert AI.unsupported_reason("opted_out", :generation) ==
               "This feature is not available for this data source."
    end
  end

  describe "AI feature gating" do
    setup do
      set_ai_config(enabled: true, api_key: "sk-test")

      Mimic.copy(Lotus.Source)
      Mimic.copy(Lotus.Source.Adapter)
      :ok
    end

    setup :set_mimic_from_context

    defp stub_opted_out_adapter(name) do
      stub(Lotus.Source, :get_source!, fn ^name ->
        %Lotus.Source.Adapter{
          name: name,
          module: Lotus.Source.Adapters.Postgres,
          state: nil,
          source_type: :postgres
        }
      end)
    end

    test "generate_query/1 returns :ai_feature_unsupported for :generation when disabled" do
      stub_opted_out_adapter("ro")

      stub(Lotus.Source.Adapter, :ai_context, fn _adapter ->
        {:ok,
         %{
           capabilities: %{
             generation: {false, "no free-form generation on this source"},
             optimization: true,
             explanation: true
           }
         }}
      end)

      assert {:error, {:ai_feature_unsupported, :generation, reason}} =
               AI.generate_query(prompt: "Count users", data_source: "ro")

      assert reason == "no free-form generation on this source"
    end

    test "suggest_optimizations/1 returns :ai_feature_unsupported for :optimization when disabled" do
      stub_opted_out_adapter("es")

      stub(Lotus.Source.Adapter, :ai_context, fn _adapter ->
        {:ok,
         %{
           capabilities: %{
             generation: true,
             optimization: {false, "Elasticsearch does not expose an execution plan"},
             explanation: true
           }
         }}
      end)

      assert {:error, {:ai_feature_unsupported, :optimization, reason}} =
               AI.suggest_optimizations(
                 statement: Statement.new("SELECT 1"),
                 data_source: "es"
               )

      assert reason == "Elasticsearch does not expose an execution plan"
    end

    test "explain_query/1 returns :ai_feature_unsupported for :explanation when disabled" do
      stub_opted_out_adapter("min")

      stub(Lotus.Source.Adapter, :ai_context, fn _adapter ->
        {:ok,
         %{
           capabilities: %{
             generation: true,
             optimization: true,
             explanation: {false, "this engine has no explanation support"}
           }
         }}
      end)

      assert {:error, {:ai_feature_unsupported, :explanation, reason}} =
               AI.explain_query(sql: "SELECT 1", data_source: "min")

      assert reason == "this engine has no explanation support"
    end
  end

  # Helper functions

  defp set_ai_config(opts) do
    Application.put_env(:lotus, :ai, opts)
    Lotus.Config.reload!()

    on_exit(fn ->
      Application.delete_env(:lotus, :ai)
      Lotus.Config.reload!()
    end)
  end
end
