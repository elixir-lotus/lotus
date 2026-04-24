defmodule Lotus.AI.Conversation do
  @moduledoc """
  Manages conversational state for AI-assisted query generation.

  Stores message history to enable multi-turn conversations where users can
  refine queries, fix errors, and have back-and-forth dialogue with the AI.

  ## Data Structure

      %{
        messages: [
          %{role: :system, content: "...", timestamp: ~U[...]},
          %{role: :user, content: "Show active users", timestamp: ~U[...]},
          %{role: :assistant, content: "I'll generate...", sql: "SELECT...", timestamp: ~U[...]},
          %{role: :error, content: "column 'status' not found", sql: "...", timestamp: ~U[...]},
          %{role: :user, content: "Fix the error", timestamp: ~U[...]}
        ],
        source_context: %{tables_analyzed: ["users", "orders"]},
        generation_count: 3,
        started_at: ~U[...],
        last_activity: ~U[...]
      }

  ## Usage

      conversation = Conversation.new()
      conversation = Conversation.add_user_message(conversation, "Show active users")
      conversation = Conversation.add_assistant_response(conversation, "Here's your query:", "SELECT * FROM users")
      conversation = Conversation.add_query_result(conversation, {:error, "column 'status' does not exist"})

      # Check if we should auto-retry based on error
      Conversation.should_auto_retry?(conversation)
      # => true
  """

  @type message :: %{
          role: :system | :user | :assistant | :error,
          content: String.t(),
          sql: String.t() | nil,
          variables: [map()] | nil,
          timestamp: DateTime.t()
        }

  @type t :: %{
          messages: [message()],
          source_context: map(),
          generation_count: non_neg_integer(),
          started_at: DateTime.t(),
          last_activity: DateTime.t()
        }

  @doc """
  Initialize a new empty conversation.

  ## Examples

      iex> conversation = Conversation.new()
      iex> conversation.messages
      []
      iex> conversation.generation_count
      0
  """
  @spec new() :: t()
  def new do
    now = DateTime.utc_now()

    %{
      messages: [],
      source_context: %{tables_analyzed: []},
      generation_count: 0,
      started_at: now,
      last_activity: now
    }
  end

  @doc """
  Add a user message to the conversation.

  ## Parameters

  - `conversation` - Current conversation state
  - `content` - User's message content

  ## Examples

      iex> conversation = Conversation.new()
      iex> conversation = Conversation.add_user_message(conversation, "Show active users")
      iex> List.last(conversation.messages).role
      :user
  """
  @spec add_user_message(t(), String.t()) :: t()
  def add_user_message(conversation, content) do
    message = %{
      role: :user,
      content: content,
      sql: nil,
      variables: nil,
      timestamp: DateTime.utc_now()
    }

    %{
      conversation
      | messages: conversation.messages ++ [message],
        last_activity: DateTime.utc_now()
    }
  end

  @doc """
  Add an assistant response to the conversation.

  ## Parameters

  - `conversation` - Current conversation state
  - `content` - Assistant's explanation or message
  - `sql` - Generated SQL query
  - `variables` - Optional list of variable configurations (default: `[]`)

  ## Examples

      iex> conversation = Conversation.new()
      iex> conversation = Conversation.add_assistant_response(conversation, "Here's your query:", "SELECT * FROM users")
      iex> message = List.last(conversation.messages)
      iex> message.role
      :assistant
      iex> message.sql
      "SELECT * FROM users"
  """
  @spec add_assistant_response(t(), String.t(), String.t(), [map()]) :: t()
  def add_assistant_response(conversation, content, sql, variables \\ []) do
    message = %{
      role: :assistant,
      content: content,
      sql: sql,
      variables: variables,
      timestamp: DateTime.utc_now()
    }

    %{
      conversation
      | messages: conversation.messages ++ [message],
        generation_count: conversation.generation_count + 1,
        last_activity: DateTime.utc_now()
    }
  end

  @doc """
  Add query execution result to the conversation for context.

  Tracks whether the last query succeeded or failed. Failed queries include
  error details that help the AI understand what went wrong and fix it.

  ## Parameters

  - `conversation` - Current conversation state
  - `result` - Query execution result tuple: `{:ok, result}` or `{:error, error}`

  ## Examples

      iex> conversation = Conversation.new()
      iex> conversation = Conversation.add_assistant_response(conversation, "Query:", "SELECT status FROM users")
      iex> conversation = Conversation.add_query_result(conversation, {:error, "column 'status' does not exist"})
      iex> message = List.last(conversation.messages)
      iex> message.role
      :error
  """
  @spec add_query_result(t(), {:ok, term()} | {:error, term()}) :: t()
  def add_query_result(conversation, {:error, error}) do
    # Find the last SQL query from assistant
    last_sql =
      conversation.messages
      |> Enum.reverse()
      |> Enum.find_value(fn msg -> if msg.role == :assistant, do: msg.sql end)

    error_message = %{
      role: :error,
      content: format_error(error),
      sql: last_sql,
      variables: nil,
      timestamp: DateTime.utc_now()
    }

    %{
      conversation
      | messages: conversation.messages ++ [error_message],
        last_activity: DateTime.utc_now()
    }
  end

  def add_query_result(conversation, {:ok, _result}) do
    # Success - no need to add to conversation, just update activity
    %{conversation | last_activity: DateTime.utc_now()}
  end

  @doc """
  Build context prompt for the LLM from conversation history.

  Formats the conversation history into a message list that can be sent
  to the LLM for context-aware generation.

  ## Parameters

  - `conversation` - Current conversation state
  - `system_prompt` - Base system prompt with database schema info

  ## Returns

  List of messages formatted for LLM consumption with roles and content.

  ## Examples

      iex> conversation = Conversation.new()
      iex>   |> Conversation.add_user_message("Show users")
      iex> messages = Conversation.build_context_messages(conversation, "You are a SQL generator")
      iex> Enum.map(messages, & &1.role)
      [:system, :user]
  """
  @spec build_context_messages(t(), String.t(), map() | nil) :: [map()]
  def build_context_messages(conversation, system_prompt, query_context \\ nil) do
    system_message = %{role: :system, content: system_prompt}

    context_messages = build_query_context_messages(query_context)

    conversation_messages =
      Enum.map(conversation.messages, fn msg ->
        case msg.role do
          :user ->
            %{role: :user, content: msg.content}

          :assistant ->
            %{role: :assistant, content: format_assistant_content(msg)}

          :error ->
            # Format error as user message asking for fix
            error_context =
              if msg.sql do
                "The previous query failed with an error:\n\nQuery: ```sql\n#{msg.sql}\n```\n\nError: #{msg.content}\n\nPlease fix this error and generate a corrected query."
              else
                "An error occurred: #{msg.content}\n\nPlease help fix this."
              end

            %{role: :user, content: error_context}
        end
      end)

    [system_message] ++ context_messages ++ conversation_messages
  end

  defp format_assistant_content(%{sql: sql, variables: variables, content: content})
       when is_binary(sql) and is_list(variables) and variables != [] do
    "#{content}\n\n```sql\n#{sql}\n```\n\n```variables\n#{Lotus.JSON.encode!(variables)}\n```"
  end

  defp format_assistant_content(%{sql: sql, content: content}) when is_binary(sql) do
    "#{content}\n\n```sql\n#{sql}\n```"
  end

  defp format_assistant_content(%{content: content}), do: content

  @doc """
  Determine if the conversation should auto-retry based on the last message.

  Returns true if the last message is an error, indicating that the AI
  should automatically attempt to fix the issue.

  ## Examples

      iex> conversation = Conversation.new()
      iex> Conversation.should_auto_retry?(conversation)
      false

      iex> conversation = Conversation.new()
      iex> conversation = Conversation.add_assistant_response(conversation, "Query:", "SELECT 1")
      iex> conversation = Conversation.add_query_result(conversation, {:error, "syntax error"})
      iex> Conversation.should_auto_retry?(conversation)
      true
  """
  @spec should_auto_retry?(t()) :: boolean()
  def should_auto_retry?(conversation) do
    case List.last(conversation.messages) do
      %{role: :error} -> true
      _ -> false
    end
  end

  @doc """
  Prune old messages to manage token usage.

  Keeps the most recent N messages while always preserving the first
  system message. This prevents token count from growing unbounded in
  long conversations.

  ## Parameters

  - `conversation` - Current conversation state
  - `keep_last` - Number of recent messages to keep (default: 10)

  ## Examples

      iex> conversation = Conversation.new()
      iex> conversation = Conversation.add_user_message(conversation, "Message 1")
      iex> conversation = Conversation.add_user_message(conversation, "Message 2")
      iex> pruned = Conversation.prune_messages(conversation, 1)
      iex> length(pruned.messages)
      1
  """
  @spec prune_messages(t(), non_neg_integer()) :: t()
  def prune_messages(conversation, keep_last \\ 10) do
    if length(conversation.messages) > keep_last do
      pruned_messages = Enum.take(conversation.messages, -keep_last)
      %{conversation | messages: pruned_messages}
    else
      conversation
    end
  end

  @doc """
  Update source context with tables analyzed during generation.

  Tracks which tables the AI has examined to provide context for
  future queries in the conversation.

  ## Parameters

  - `conversation` - Current conversation state
  - `table_names` - List of table names that were analyzed

  ## Examples

      iex> conversation = Conversation.new()
      iex> conversation = Conversation.update_source_context(conversation, ["users", "orders"])
      iex> conversation.source_context.tables_analyzed
      ["users", "orders"]
  """
  @spec update_source_context(t(), [String.t()]) :: t()
  def update_source_context(conversation, table_names) do
    current_tables = conversation.source_context[:tables_analyzed] || []
    updated_tables = Enum.uniq(current_tables ++ table_names)

    %{
      conversation
      | source_context: %{conversation.source_context | tables_analyzed: updated_tables}
    }
  end

  # Private helpers

  defp build_query_context_messages(nil), do: []

  defp build_query_context_messages(%{sql: sql, variables: variables})
       when is_binary(sql) and sql != "" do
    content =
      if is_list(variables) and variables != [] do
        "The user already has this query in their editor:\n\n```sql\n#{sql}\n```\n\n```variables\n#{Lotus.JSON.encode!(variables)}\n```"
      else
        "The user already has this query in their editor:\n\n```sql\n#{sql}\n```"
      end

    [
      %{role: :assistant, content: content}
    ]
  end

  defp build_query_context_messages(_), do: []

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
