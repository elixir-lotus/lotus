defmodule Lotus.AI do
  @moduledoc """
  AI-powered query generation for Lotus.

  ## Configuration

  Configure AI in your application config:

      config :lotus,
        ai: [
          enabled: true,
          model: "anthropic:claude-opus-4",
          api_key: {:system, "ANTHROPIC_API_KEY"}
        ]

  The `model` key accepts any model string supported by ReqLLM, e.g.:

  - `"openai:gpt-4o"` (default)
  - `"anthropic:claude-opus-4"`
  - `"google:gemini-2.0-flash"`
  - `"groq:llama-3.3-70b-versatile"`
  - Any other provider supported by ReqLLM

  ## Usage

      {:ok, result} = Lotus.AI.generate_query(
        prompt: "Show me all users who signed up last month",
        data_source: "postgres"
      )

      # Returns:
      # %{
      #   sql: "SELECT * FROM users WHERE created_at >= ...",
      #   variables: [],
      #   model: "openai:gpt-4o",
      #   usage: %{total_tokens: 150}
      # }

  ## Error Handling

  The `generate_query/1` function returns structured error tuples that clients can
  pattern match on for custom handling and internationalization (i18n):

  - `{:ok, result}` - Successfully generated SQL query
  - `{:error, :not_configured}` - AI features not enabled in config
  - `{:error, :api_key_not_configured}` - API key missing or invalid
  - `{:error, {:unable_to_generate, reason}}` - LLM refused (non-SQL question)
  - `{:error, term}` - Other errors (API failures, network issues, etc.)
  """

  alias Lotus.AI.{QueryExplainer, QueryGenerator, QueryOptimizer}
  alias Lotus.Source
  alias Lotus.Source.Adapter

  @default_model "openai:gpt-4o"
  @ai_features ~w(generation optimization explanation)a

  @typedoc "The set of AI features an adapter may support per-source."
  @type feature :: :generation | :optimization | :explanation

  @doc """
  Generate SQL query from natural language prompt with conversation context.

  Enables multi-turn conversations by accepting conversation history. The AI
  can refine queries, fix errors, and provide iterative improvements.

  ## Options

  - `:prompt` (required) - Natural language description of desired query
  - `:data_source` (required) - Name of the data source to query against
  - `:conversation` (optional) - Conversation struct with message history
  - `:read_only` (optional) - When `true` (default), the AI only generates read-only
    queries. Set to `false` to allow the AI to generate write queries.

  ## Returns

  - `{:ok, result}` - Successfully generated SQL with metadata
  - `{:error, term}` - Structured error tuple (see module docs for error types)

  ## Examples

      # Simple single-turn (same as generate_query/1)
      {:ok, result} = Lotus.AI.generate_query_with_context(
        prompt: "Show active users",
        data_source: "postgres"
      )

      # Multi-turn with conversation history
      conversation = Conversation.new()
      conversation = Conversation.add_user_message(conversation, "Show active users")

      {:ok, result} = Lotus.AI.generate_query_with_context(
        prompt: "Show active users",
        data_source: "postgres",
        conversation: conversation
      )

      # If query fails, add error to conversation
      conversation = Conversation.add_query_result(conversation, {:error, "column 'status' not found"})

      # AI can now fix the error with full context
      {:ok, fixed_result} = Lotus.AI.generate_query_with_context(
        prompt: "Fix the error",
        data_source: "postgres",
        conversation: conversation
      )
  """
  @spec generate_query_with_context(keyword()) :: {:ok, map()} | {:error, term()}
  def generate_query_with_context(opts) do
    with {:ok, config} <- get_ai_config(),
         :ok <- check_feature(opts[:data_source], :generation),
         {:ok, response} <-
           QueryGenerator.generate_sql(config.model,
             prompt: opts[:prompt],
             data_source: opts[:data_source],
             conversation: opts[:conversation],
             query_context: opts[:query_context],
             api_key: config.api_key,
             read_only: Keyword.get(opts, :read_only, true)
           ) do
      {:ok,
       %{
         sql: response.content,
         variables: Map.get(response, :variables, []),
         model: response.model,
         usage: response.usage
       }}
    end
  end

  @doc """
  Generate SQL query from natural language prompt.

  Uses the globally configured AI provider from application config.

  ## Options

  - `:prompt` (required) - Natural language description of desired query
  - `:data_source` (required) - Name of the data source to query against
  - `:read_only` (optional) - When `true` (default), the AI only generates read-only
    queries. Set to `false` to allow the AI to generate write queries.

  ## Returns

  - `{:ok, result}` - Successfully generated SQL with metadata
  - `{:error, term}` - Structured error tuple (see module docs for error types)

  ## Examples

      {:ok, result} = Lotus.AI.generate_query(
        prompt: "Count active users by signup month",
        data_source: "postgres"
      )

      result.sql
      # => "SELECT DATE_TRUNC('month', created_at) as month, COUNT(*) FROM users WHERE status = 'active' GROUP BY month"

      result.model
      # => "openai:gpt-4o"

      result.usage
      # => %{prompt_tokens: 150, completion_tokens: 50, total_tokens: 200}

      # Error handling with pattern matching
      {:error, :not_configured} = Lotus.AI.generate_query(
        prompt: "some query",
        data_source: "postgres"
      )
  """
  @spec generate_query(keyword()) :: {:ok, map()} | {:error, term()}
  def generate_query(opts) do
    with {:ok, config} <- get_ai_config(),
         :ok <- check_feature(opts[:data_source], :generation),
         {:ok, response} <-
           QueryGenerator.generate_sql(config.model,
             prompt: opts[:prompt],
             data_source: opts[:data_source],
             api_key: config.api_key,
             read_only: Keyword.get(opts, :read_only, true)
           ) do
      {:ok,
       %{
         sql: response.content,
         variables: Map.get(response, :variables, []),
         model: response.model,
         usage: response.usage
       }}
    end
  end

  @doc """
  Get AI-powered optimization suggestions for a statement.

  Runs the adapter's `prepare_for_analysis/2` + `query_plan/4` to get an
  execution plan (when the engine exposes one), then asks the AI to
  review the statement and the plan for potential improvements. Adapters
  that can't produce a plan still get structural suggestions.

  ## Options

    * `:statement` (required) — a `%Lotus.Query.Statement{}` to review.
    * `:data_source` (required) — name of the data source.
    * `:search_path` (optional) — Postgres search path.

  ## Returns

    * `{:ok, result}` — map with `:suggestions`, `:model`, `:usage`.
    * `{:error, :ai_not_supported_for_source}` — the adapter opted out
      of AI via its `ai_context/1` callback.
    * `{:error, term}` — other failure.
  """
  @spec suggest_optimizations(keyword()) :: {:ok, map()} | {:error, term()}
  def suggest_optimizations(opts) do
    with {:ok, config} <- get_ai_config(),
         :ok <- check_feature(opts[:data_source], :optimization) do
      QueryOptimizer.suggest_optimizations(config.model,
        statement: Keyword.fetch!(opts, :statement),
        data_source: opts[:data_source],
        search_path: opts[:search_path],
        api_key: config.api_key
      )
    end
  end

  @doc """
  Get an AI-powered plain-language explanation of a SQL query.

  Supports explaining a full query or a selected fragment. When a fragment
  is provided, the full query is sent as context so the AI can explain even
  isolated terms accurately.

  ## Options

  - `:sql` (required) - The full SQL query
  - `:fragment` (optional) - A selected portion of the query to explain
  - `:data_source` (required) - Name of the data source to resolve schema context

  ## Returns

  - `{:ok, result}` - Map with `:explanation`, `:model`, and `:usage`
  - `{:error, term}` - Structured error tuple

  ## Examples

      # Explain a full query
      {:ok, result} = Lotus.AI.explain_query(
        sql: "SELECT d.name, COUNT(o.id) FROM departments d LEFT JOIN orders o ...",
        data_source: "postgres"
      )

      result.explanation
      # => "This query shows departments ranked by total order count..."

      # Explain a selected fragment
      {:ok, result} = Lotus.AI.explain_query(
        sql: "SELECT d.name FROM departments d LEFT JOIN employees e ON e.department_id = d.id",
        fragment: "LEFT JOIN employees e ON e.department_id = d.id",
        data_source: "postgres"
      )
  """
  @spec explain_query(keyword()) :: {:ok, map()} | {:error, term()}
  def explain_query(opts) do
    with {:ok, config} <- get_ai_config(),
         :ok <- check_feature(opts[:data_source], :explanation) do
      QueryExplainer.explain_query(config.model,
        sql: opts[:sql],
        fragment: opts[:fragment],
        data_source: opts[:data_source],
        api_key: config.api_key
      )
    end
  end

  @doc """
  Check if AI features are enabled and configured.

  Returns `true` if AI is properly configured, `false` otherwise.

  ## Examples

      Lotus.AI.enabled?()
      # => true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case get_ai_config() do
      {:ok, _config} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Check whether a specific AI feature is supported for the given source.

  Reads `ai_context.capabilities[feature]` via
  `Lotus.Source.Adapter.ai_context/1`. Returns `false` if the adapter
  opts out of AI entirely (returns `{:error, _}` from `ai_context/1`).

  `feature` is one of `:generation`, `:optimization`, `:explanation`.

  UIs should call this before rendering each AI button to hide or
  disable options the data source doesn't support.
  """
  @spec supports?(String.t(), feature()) :: boolean()
  def supports?(source_name, feature) when is_binary(source_name) and feature in @ai_features do
    case Adapter.ai_context(Source.get_source!(source_name)) do
      {:ok, %{capabilities: caps}} ->
        case Map.get(caps, feature) do
          true -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Return the adapter-declared (or generic fallback) reason a feature is
  unsupported for this source, or `nil` when supported.

  Reasons from untrusted adapters are replaced with a generic fallback
  at the dispatch layer — UIs can surface this string verbatim.
  """
  @spec unsupported_reason(String.t(), feature()) :: String.t() | nil
  def unsupported_reason(source_name, feature)
      when is_binary(source_name) and feature in @ai_features do
    case Adapter.ai_context(Source.get_source!(source_name)) do
      {:ok, %{capabilities: caps}} ->
        case Map.get(caps, feature) do
          true -> nil
          {false, reason} -> reason
          _ -> "This feature is not available for this data source."
        end

      {:error, _} ->
        "This feature is not available for this data source."
    end
  end

  # Gate a feature call — returns `:ok` when supported, else an
  # `{:error, {:ai_feature_unsupported, feature, reason}}` tuple the
  # public AI functions propagate unchanged.
  defp check_feature(nil, _feature), do: {:error, :missing_data_source}

  defp check_feature(source_name, feature) when is_binary(source_name) do
    if supports?(source_name, feature) do
      :ok
    else
      {:error, {:ai_feature_unsupported, feature, unsupported_reason(source_name, feature)}}
    end
  end

  @doc """
  Get the configured AI model string.

  Returns the full model string (e.g. `"openai:gpt-4o"`) if configured.

  ## Examples

      Lotus.AI.model()
      # => {:ok, "openai:gpt-4o"}
  """
  @spec model() :: {:ok, String.t()} | {:error, :not_configured}
  def model do
    case get_ai_config() do
      {:ok, config} -> {:ok, config.model}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_ai_config do
    ai_config = Lotus.Config.get(:ai) || []

    if ai_config[:enabled] do
      api_key = resolve_secret(ai_config[:api_key])

      if api_key do
        model = ai_config[:model] || @default_model

        {:ok,
         %{
           model: model,
           api_key: api_key
         }}
      else
        {:error, :api_key_not_configured}
      end
    else
      {:error, :not_configured}
    end
  end

  defp resolve_secret({:system, env_var}) when is_binary(env_var) do
    System.get_env(env_var)
  end

  defp resolve_secret(value) when is_binary(value), do: value
  defp resolve_secret(_), do: nil
end
