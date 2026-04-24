defmodule Lotus.AI.QueryExplainer do
  @moduledoc """
  Generates AI-powered plain-language explanations for SQL queries.

  Supports explaining a full query or a selected fragment in context
  of the full query.
  """

  alias Lotus.AI.Actions
  alias Lotus.AI.Prompts.Explanation
  alias Lotus.AI.Tool

  @doc """
  Generate a plain-language explanation for a SQL query or fragment.

  ## Options

  - `:sql` (required) - The full SQL query
  - `:fragment` (optional) - A selected portion of the query to explain
  - `:data_source` (required) - Name of the data source
  - `:api_key` (required) - API key for the LLM provider
  - `:temperature` (optional) - LLM temperature (default: `0.2`)

  ## Returns

  - `{:ok, result}` - Map with `:explanation`, `:model`, and `:usage`
  - `{:error, term}` - Error tuple
  """
  @spec explain_query(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def explain_query(model_string, opts) do
    data_source = Keyword.fetch!(opts, :data_source)
    sql = Keyword.fetch!(opts, :sql)
    fragment = Keyword.get(opts, :fragment)
    api_key = Keyword.fetch!(opts, :api_key)
    temperature = Keyword.get(opts, :temperature, 0.2)

    database_type = Lotus.Source.source_type(data_source)

    system_prompt = Explanation.system_prompt(database_type)

    user_prompt =
      if fragment do
        Explanation.fragment_prompt(fragment, sql)
      else
        Explanation.user_prompt(sql)
      end

    tools = build_tools(data_source)
    messages = build_messages(system_prompt, user_prompt)
    context = ReqLLM.Context.new(messages)

    Tool.run(model_string, context, tools, api_key: api_key, temperature: temperature)
    |> handle_response(model_string)
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
    {:ok,
     %{
       explanation: ReqLLM.Response.text(response),
       model: model_string,
       usage: Tool.normalize_usage(ReqLLM.Response.usage(response))
     }}
  end

  defp handle_response({:error, error}, _model_string), do: {:error, error}
end
