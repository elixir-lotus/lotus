defmodule Lotus.AI.QueryOptimizer do
  @moduledoc """
  Generates AI-powered optimization suggestions for a query.

  Runs the adapter's `prepare_for_analysis/2` to resolve Lotus template
  syntax into a form parseable by the engine's diagnostic endpoint, calls
  `query_plan/4` to get an execution plan (when available), and sends
  both the statement and the plan to the LLM for review.

  The module is adapter-agnostic — SQL dialects produce EXPLAIN output,
  non-SQL adapters can produce whatever their native profile/diagnostic
  API returns (or `nil` if unavailable; the LLM then reviews the
  statement structurally).
  """

  alias Lotus.AI.Actions
  alias Lotus.AI.Prompts.Optimization
  alias Lotus.AI.Tool
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter

  @doc """
  Generate optimization suggestions for a statement.

  ## Options

    * `:statement` (required) — a `%Lotus.Query.Statement{}` to review.
    * `:data_source` (required) — name of the data source.
    * `:api_key` (required) — API key for the LLM provider.
    * `:search_path` (optional) — Postgres search path.
    * `:temperature` (optional) — LLM temperature (default: `0.1`).

  ## Returns

    * `{:ok, result}` — map with `:suggestions`, `:model`, `:usage`.
    * `{:error, :ai_not_supported_for_source}` — adapter returned
      `{:error, _}` from `ai_context/1`.
    * `{:error, term}` — other failure.
  """
  @type optimization_response :: %{
          suggestions: [map()],
          model: String.t(),
          usage: %{
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
        }

  @spec suggest_optimizations(String.t(), keyword()) ::
          {:ok, optimization_response()} | {:error, term()}
  def suggest_optimizations(model_string, opts) do
    data_source = Keyword.fetch!(opts, :data_source)
    statement = Keyword.fetch!(opts, :statement)
    api_key = Keyword.fetch!(opts, :api_key)
    search_path = Keyword.get(opts, :search_path)
    temperature = Keyword.get(opts, :temperature, 0.1)

    adapter = Lotus.Source.get_source!(data_source)

    case Adapter.ai_context(adapter) do
      {:ok, ai_context} ->
        execution_plan = get_execution_plan(adapter, statement, search_path: search_path)

        system_prompt = Optimization.system_prompt(ai_context)
        user_prompt = Optimization.user_prompt(statement.text, execution_plan)

        tools = build_tools(data_source)
        messages = build_messages(system_prompt, user_prompt)
        context = ReqLLM.Context.new(messages)

        Tool.run(model_string, context, tools, api_key: api_key, temperature: temperature)
        |> handle_response(model_string)

      {:error, :ai_not_supported} ->
        {:error, :ai_not_supported_for_source}

      {:error, _} = err ->
        err
    end
  end

  # Returns the engine's execution plan for the statement (a string), or
  # `nil` when the adapter can't produce one (no plan API, or
  # `prepare_for_analysis/2` declined). The prompt branches on plan
  # availability — a `nil` plan still produces useful structural
  # suggestions.
  defp get_execution_plan(adapter, %Statement{} = statement, opts) do
    with {:ok, prepared} <- Adapter.prepare_for_analysis(adapter, statement),
         {:ok, plan} <- Adapter.query_plan(adapter, prepared.text, prepared.params, opts) do
      plan
    else
      _ -> nil
    end
  end

  defp build_tools(data_source) do
    [
      Tool.from_action(Actions.DescribeTable, bind: %{data_source: data_source})
    ]
  end

  defp build_messages(system_prompt, user_prompt) do
    [
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(user_prompt)
    ]
  end

  defp handle_response({:ok, response}, model_string) do
    content = ReqLLM.Response.text(response)

    {:ok,
     %{
       suggestions: Optimization.parse_suggestions(content),
       model: model_string,
       usage: Tool.normalize_usage(ReqLLM.Response.usage(response))
     }}
  end

  defp handle_response({:error, error}, _model_string), do: {:error, error}
end
