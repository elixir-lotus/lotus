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

  ## The dependency

  The AI features use [ReqLLM](https://hex.pm/packages/req_llm), an
  optional dependency of Lotus: add it to your app's deps to use them.

      {:req_llm, "~> 1.29"}

  Without it, `available?/0` is `false`, `enabled?/0` is `false` even when
  AI is configured (with a warning, once), and the AI functions return
  `{:error, :dependency_missing}`.

  ## Usage

      {:ok, result} = Lotus.AI.generate_query(
        prompt: "Show me all users who signed up last month",
        data_source: "postgres"
      )

      # Returns:
      # %{
      #   statement: "SELECT * FROM users WHERE created_at >= ...",
      #   variables: [],
      #   model: "openai:gpt-4o",
      #   usage: %{total_tokens: 150}
      # }

  ## Error Handling

  The `generate_query/1` function returns structured error tuples that clients can
  pattern match on for custom handling and internationalization (i18n):

  - `{:ok, result}` - Successfully generated statement
  - `{:error, :not_configured}` - AI features not enabled in config
  - `{:error, :dependency_missing}` - AI enabled in config, but `req_llm`
    is not installed
  - `{:error, :api_key_not_configured}` - API key missing or invalid
  - `{:error, {:unable_to_generate, reason}}` - LLM refused (not a data question)
  - `{:error, term}` - Other errors (API failures, network issues, etc.)
  """

  require Logger

  alias Lotus.AI.{QueryExplainer, QueryGenerator, QueryOptimizer}
  alias Lotus.Source
  alias Lotus.Source.Adapter

  # Compiled only with ReqLLM; called only when it is (`available?/0`).
  @compile {:no_warn_undefined, [QueryExplainer, QueryGenerator, QueryOptimizer]}

  @default_model "openai:gpt-4o"
  @ai_features ~w(generation optimization explanation)a

  @typedoc "The set of AI features an adapter may support per-source."
  @type feature :: :generation | :optimization | :explanation

  @doc """
  Generate a query statement from a natural language prompt, with conversation context.

  Enables multi-turn conversations by accepting conversation history. The AI
  can refine queries, fix errors, and provide iterative improvements.

  ## Options

  - `:prompt` (required) - Natural language description of desired query
  - `:data_source` (required) - Name of the data source to query against
  - `:conversation` (optional) - Conversation struct with message history
  - `:read_only` (optional) - When `true` (default), the AI only generates read-only
    queries. Set to `false` to allow the AI to generate write queries.

  ## Returns

  - `{:ok, result}` - Successfully generated statement with metadata
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
           QueryGenerator.generate_statement(
             config.model,
             [
               prompt: opts[:prompt],
               data_source: opts[:data_source],
               conversation: opts[:conversation],
               query_context: opts[:query_context],
               api_key: config.api_key,
               read_only: Keyword.get(opts, :read_only, true)
             ] ++ actor_opts(opts)
           ) do
      {:ok,
       %{
         statement: response.content,
         variables: Map.get(response, :variables, []),
         model: response.model,
         usage: response.usage
       }}
    end
  end

  @doc """
  Generate a query statement from a natural language prompt.

  Uses the globally configured AI provider from application config.

  ## Options

  - `:prompt` (required) - Natural language description of desired query
  - `:data_source` (required) - Name of the data source to query against
  - `:read_only` (optional) - When `true` (default), the AI only generates read-only
    queries. Set to `false` to allow the AI to generate write queries.

  ## Returns

  - `{:ok, result}` - Successfully generated statement with metadata
  - `{:error, term}` - Structured error tuple (see module docs for error types)

  ## Examples

      {:ok, result} = Lotus.AI.generate_query(
        prompt: "Count active users by signup month",
        data_source: "postgres"
      )

      result.statement
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
           QueryGenerator.generate_statement(
             config.model,
             [
               prompt: opts[:prompt],
               data_source: opts[:data_source],
               api_key: config.api_key,
               read_only: Keyword.get(opts, :read_only, true)
             ] ++ actor_opts(opts)
           ) do
      {:ok,
       %{
         statement: response.content,
         variables: Map.get(response, :variables, []),
         model: response.model,
         usage: response.usage
       }}
    end
  end

  @doc """
  Get AI-powered optimization suggestions for a statement.

  Runs the adapter's `prepare_for_analysis/2` + `query_plan/3` to get an
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
      QueryOptimizer.suggest_optimizations(
        config.model,
        [
          statement: Keyword.fetch!(opts, :statement),
          data_source: opts[:data_source],
          search_path: opts[:search_path],
          api_key: config.api_key
        ] ++ actor_opts(opts)
      )
    end
  end

  @doc """
  Get an AI-powered plain-language explanation of a query.

  Supports explaining a full query or a selected fragment. When a fragment
  is provided, the full query is sent as context so the AI can explain even
  isolated terms accurately.

  ## Options

  - `:statement` (required) - The full query statement
  - `:fragment` (optional) - A selected portion of the query to explain
  - `:data_source` (required) - Name of the data source to resolve schema context

  ## Returns

  - `{:ok, result}` - Map with `:explanation`, `:model`, and `:usage`
  - `{:error, term}` - Structured error tuple

  ## Examples

      # Explain a full query
      {:ok, result} = Lotus.AI.explain_query(
        statement: "SELECT d.name, COUNT(o.id) FROM departments d LEFT JOIN orders o ...",
        data_source: "postgres"
      )

      result.explanation
      # => "This query shows departments ranked by total order count..."

      # Explain a selected fragment
      {:ok, result} = Lotus.AI.explain_query(
        statement: "SELECT d.name FROM departments d LEFT JOIN employees e ON e.department_id = d.id",
        fragment: "LEFT JOIN employees e ON e.department_id = d.id",
        data_source: "postgres"
      )
  """
  @spec explain_query(keyword()) :: {:ok, map()} | {:error, term()}
  def explain_query(opts) do
    with {:ok, config} <- get_ai_config(),
         :ok <- check_feature(opts[:data_source], :explanation) do
      QueryExplainer.explain_query(
        config.model,
        [
          statement: opts[:statement],
          fragment: opts[:fragment],
          data_source: opts[:data_source],
          api_key: config.api_key
        ] ++ actor_opts(opts)
      )
    end
  end

  @doc """
  Whether the AI features can run on this node: whether ReqLLM, an
  optional dependency, is loaded. Fixed for the life of the node; whether
  AI is switched on is `enabled?/0`.

      Lotus.AI.available?()
      # => true
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(dependency())

  # The module the AI features need. An application setting only so that
  # the tests can stand for a node without it.
  defp dependency, do: Application.get_env(:lotus, :__ai_dependency__, ReqLLM)

  @doc """
  Check if AI features are enabled and configured.

  Returns `true` if AI is switched on and configured, and can run
  (`available?/0`), `false` otherwise. AI switched on without its
  dependency logs a warning, once. It reads the configuration on each
  call, so a setting changed at runtime counts at once.

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
  @spec model() ::
          {:ok, String.t()}
          | {:error, :not_configured | :dependency_missing | :api_key_not_configured}
  def model do
    case get_ai_config() do
      {:ok, config} -> {:ok, config.model}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_ai_config do
    ai_config = Lotus.Config.get(:ai) || []

    cond do
      !ai_config[:enabled] -> {:error, :not_configured}
      not available?() -> warn_missing_dependency()
      true -> ai_config(ai_config)
    end
  end

  defp ai_config(ai_config) do
    api_key = resolve_secret(ai_config[:api_key])

    if api_key do
      {:ok, %{model: ai_config[:model] || @default_model, api_key: api_key}}
    else
      {:error, :api_key_not_configured}
    end
  end

  # AI switched on, and its dependency missing: said once a node, as it is
  # asked on every render of the UIs that show AI.
  defp warn_missing_dependency do
    unless :persistent_term.get({__MODULE__, :warned_missing}, false) do
      :persistent_term.put({__MODULE__, :warned_missing}, true)

      Logger.warning(
        "Lotus AI is enabled in the config, but its dependency is missing: " <>
          ~s(add {:req_llm, "~> 1.29"} to your deps to use it. AI stays off.)
      )
    end

    {:error, :dependency_missing}
  end

  defp resolve_secret({:system, env_var}) when is_binary(env_var) do
    System.get_env(env_var)
  end

  defp resolve_secret(value) when is_binary(value), do: value
  defp resolve_secret(_), do: nil

  # Forward the caller's actor to the AI layer. Every query the AI runs and
  # every table it lists goes through Lotus with these options, so an
  # access-control plug or a scoped visibility resolver sees the same actor
  # for an AI-initiated action as for one the user made directly. Keys the
  # caller omitted are left out rather than passed as nil.
  defp actor_opts(opts) do
    Enum.flat_map([:context, :scope], fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end
end
