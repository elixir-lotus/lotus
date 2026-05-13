defmodule Lotus.AI.QueryGenerator do
  @moduledoc """
  Generates SQL from natural language using ReqLLM.

  Handles tool building, message handling, and response extraction.
  Any provider supported by ReqLLM can be used by passing a model
  string like `"openai:gpt-4o"` or `"anthropic:claude-opus-4"`.
  """

  alias Lotus.AI.Actions
  alias Lotus.AI.Conversation
  alias Lotus.AI.Prompts.QueryGeneration
  alias Lotus.AI.Tool
  alias Lotus.Query.Statement
  alias Lotus.Source
  alias Lotus.Source.Adapter

  @doc """
  Validate that a config contains a non-empty API key string.
  """
  @spec validate_key(map()) :: :ok | {:error, String.t()}
  def validate_key(config) do
    if is_binary(config.api_key) and String.length(config.api_key) > 0 do
      :ok
    else
      {:error, "API key must be a non-empty string"}
    end
  end

  @doc """
  Generate SQL using the given model string and options.

  The model string should be in ReqLLM format, e.g. `"openai:gpt-4o"`,
  `"anthropic:claude-opus-4"`, `"google:gemini-2.0-flash"`.

  ## Options

  - `:prompt` (required) - Natural language query
  - `:data_source` (required) - Name of the data source
  - `:api_key` (required) - API key for the provider
  - `:conversation` - Conversation struct for multi-turn
  - `:query_context` - Additional context for the query
  - `:read_only` - Whether to restrict to read-only SQL (default: true)
  - `:temperature` - LLM temperature (default: 0.1)
  """
  @type sql_response :: %{
          content: String.t(),
          model: String.t(),
          variables: [map()],
          usage: %{
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
        }

  @spec generate_sql(String.t(), keyword()) :: {:ok, sql_response()} | {:error, term()}
  def generate_sql(model_string, opts) do
    data_source = Keyword.fetch!(opts, :data_source)
    prompt = Keyword.fetch!(opts, :prompt)
    conversation = Keyword.get(opts, :conversation)
    query_context = Keyword.get(opts, :query_context)
    read_only = Keyword.get(opts, :read_only, true)
    api_key = Keyword.fetch!(opts, :api_key)
    temperature = Keyword.get(opts, :temperature, 0.1)

    adapter = Source.resolve!(data_source, nil)

    case Adapter.ai_context(adapter) do
      {:ok, ai_context} ->
        {:ok, all_schemas} = Lotus.Schema.list_schemas(data_source)
        {:ok, tables} = Lotus.Schema.list_tables(data_source, schemas: all_schemas)
        table_names = extract_table_names(tables)

        system_prompt =
          QueryGeneration.system_prompt(ai_context, table_names, read_only: read_only)

        tools = build_tools(data_source)
        messages = build_messages(conversation, prompt, system_prompt, query_context)
        context = build_context(messages)

        Tool.run(model_string, context, tools, api_key: api_key, temperature: temperature)
        |> handle_response(model_string, data_source)

      {:error, :ai_not_supported} ->
        {:error, :ai_not_supported_for_source}

      {:error, _} = err ->
        err
    end
  end

  defp handle_response({:ok, response}, model_string, data_source) do
    content = ReqLLM.Response.text(response)

    case QueryGeneration.extract_response(content) do
      {:ok, %{sql: sql, variables: variables}} ->
        {:ok, build_success_response(response, model_string, sql, variables)}

      {:error, {:unable_to_generate, candidate}} ->
        adapter = Source.resolve!(data_source, nil)
        statement = Statement.new(candidate)

        case Adapter.validate_statement(adapter, statement, []) do
          :ok ->
            variables = QueryGeneration.extract_variables(candidate)
            {:ok, build_success_response(response, model_string, candidate, variables)}

          {:error, _reason} ->
            {:error, {:unable_to_generate, candidate}}
        end
    end
  end

  defp handle_response({:error, error}, _model_string, _data_source), do: {:error, error}

  defp build_success_response(response, model_string, sql, variables) do
    %{
      content: sql,
      model: model_string,
      variables: variables,
      usage: Tool.normalize_usage(ReqLLM.Response.usage(response))
    }
  end

  # Tools

  defp build_tools(data_source) do
    bind = %{data_source: data_source}

    [
      Tool.from_action(Actions.ListSchemas, bind: bind),
      Tool.from_action(Actions.ListTables, bind: bind),
      Tool.from_action(Actions.DescribeTable, bind: bind),
      Tool.from_action(Actions.GetColumnValues, bind: bind),
      Tool.from_action(Actions.ValidateSQL, bind: bind)
    ]
  end

  # Messages

  defp extract_table_names(tables) do
    Enum.map(tables, fn
      {schema, table} when not is_nil(schema) -> "#{schema}.#{table}"
      table -> table
    end)
  end

  defp build_messages(conversation, prompt, system_prompt, query_context) do
    if conversation && conversation.messages != [] do
      build_conversation_messages(conversation, prompt, system_prompt, query_context)
    else
      build_single_turn_messages(prompt, system_prompt, query_context)
    end
  end

  defp build_single_turn_messages(prompt, system_prompt, query_context) do
    Conversation.new()
    |> Conversation.add_user_message(prompt)
    |> Conversation.build_context_messages(system_prompt, query_context)
    |> convert_to_req_llm_messages()
  end

  defp build_conversation_messages(conversation, prompt, system_prompt, query_context) do
    conversation
    |> Conversation.build_context_messages(system_prompt, query_context)
    |> convert_to_req_llm_messages()
    |> maybe_add_current_prompt(conversation, prompt)
  end

  defp convert_to_req_llm_messages(messages) do
    Enum.map(messages, fn msg ->
      case msg.role do
        :system -> ReqLLM.Context.system(msg.content)
        :user -> ReqLLM.Context.user(msg.content)
        :assistant -> ReqLLM.Context.assistant(msg.content)
      end
    end)
  end

  defp build_context(messages) do
    ReqLLM.Context.new(messages)
  end

  defp maybe_add_current_prompt(messages, conversation, prompt) do
    last_user_msg = find_last_user_message(conversation)

    if last_user_msg && last_user_msg.content == prompt do
      messages
    else
      messages ++ [ReqLLM.Context.user(prompt)]
    end
  end

  defp find_last_user_message(conversation) do
    conversation.messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :user))
  end
end
