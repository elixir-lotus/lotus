defmodule Lotus.AI.ConversationTest do
  use ExUnit.Case, async: true

  alias Lotus.AI.Conversation

  doctest Lotus.AI.Conversation

  describe "new/0" do
    test "creates an empty conversation" do
      conversation = Conversation.new()

      assert conversation.messages == []
      assert conversation.generation_count == 0
      assert conversation.source_context == %{tables_analyzed: []}
      assert %DateTime{} = conversation.started_at
      assert %DateTime{} = conversation.last_activity
    end
  end

  describe "add_user_message/2" do
    test "adds a user message to the conversation" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("Show active users")

      assert length(conversation.messages) == 1
      message = List.first(conversation.messages)

      assert message.role == :user
      assert message.content == "Show active users"
      assert message.sql == nil
      assert %DateTime{} = message.timestamp
    end

    test "appends multiple user messages in order" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("First message")
        |> Conversation.add_user_message("Second message")

      assert length(conversation.messages) == 2
      assert Enum.at(conversation.messages, 0).content == "First message"
      assert Enum.at(conversation.messages, 1).content == "Second message"
    end
  end

  describe "add_assistant_response/3" do
    test "adds an assistant response with SQL" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Here's your query:", "SELECT * FROM users")

      assert length(conversation.messages) == 1
      message = List.first(conversation.messages)

      assert message.role == :assistant
      assert message.content == "Here's your query:"
      assert message.sql == "SELECT * FROM users"
      assert %DateTime{} = message.timestamp
    end

    test "increments generation count" do
      conversation = Conversation.new()
      assert conversation.generation_count == 0

      conversation = Conversation.add_assistant_response(conversation, "Query:", "SELECT 1")
      assert conversation.generation_count == 1

      conversation = Conversation.add_assistant_response(conversation, "Another:", "SELECT 2")
      assert conversation.generation_count == 2
    end
  end

  describe "add_assistant_response/4" do
    test "stores variables in message" do
      variables = [%{"name" => "status", "type" => "text", "widget" => "select"}]

      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response(
          "Here's your query:",
          "SELECT * FROM orders WHERE status = {{status}}",
          variables
        )

      message = List.first(conversation.messages)

      assert message.variables == variables
    end

    test "defaults variables to empty list when not provided" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT 1")

      message = List.first(conversation.messages)

      assert message.variables == []
    end
  end

  describe "add_query_result/2" do
    test "adds error message when query fails" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT status FROM users")
        |> Conversation.add_query_result({:error, "column 'status' does not exist"})

      error_message = List.last(conversation.messages)

      assert error_message.role == :error
      assert error_message.content == "column 'status' does not exist"
      assert error_message.sql == "SELECT status FROM users"
    end

    test "does not add message when query succeeds" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT * FROM users")
        |> Conversation.add_query_result({:ok, %{rows: [], columns: []}})

      assert length(conversation.messages) == 1
      assert List.first(conversation.messages).role == :assistant
    end

    test "handles error exceptions" do
      error = %RuntimeError{message: "Database connection failed"}

      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT 1")
        |> Conversation.add_query_result({:error, error})

      error_message = List.last(conversation.messages)
      assert error_message.content == "Database connection failed"
    end
  end

  describe "build_context_messages/2" do
    test "includes system prompt as first message" do
      conversation = Conversation.new()
      messages = Conversation.build_context_messages(conversation, "You are a SQL generator")

      assert length(messages) == 1
      assert List.first(messages) == %{role: :system, content: "You are a SQL generator"}
    end

    test "converts user messages" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("Show users")

      messages = Conversation.build_context_messages(conversation, "System prompt")

      user_message = Enum.at(messages, 1)
      assert user_message.role == :user
      assert user_message.content == "Show users"
    end

    test "converts assistant messages with SQL" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Here's your query:", "SELECT * FROM users")

      messages = Conversation.build_context_messages(conversation, "System prompt")

      assistant_message = Enum.at(messages, 1)
      assert assistant_message.role == :assistant
      assert assistant_message.content =~ "Here's your query:"
      assert assistant_message.content =~ "```sql\nSELECT * FROM users\n```"
    end

    test "converts error messages to user messages asking for fix" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT status FROM users")
        |> Conversation.add_query_result({:error, "column 'status' does not exist"})

      messages = Conversation.build_context_messages(conversation, "System prompt")

      error_as_user = List.last(messages)
      assert error_as_user.role == :user
      assert error_as_user.content =~ "previous query failed"
      assert error_as_user.content =~ "column 'status' does not exist"
      assert error_as_user.content =~ "SELECT status FROM users"
    end

    test "includes variables block in assistant context when variables are present" do
      variables = [%{"name" => "status", "type" => "text", "widget" => "select"}]

      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response(
          "Here's your query:",
          "SELECT * FROM orders WHERE status = {{status}}",
          variables
        )

      messages = Conversation.build_context_messages(conversation, "System prompt")

      assistant_message = Enum.at(messages, 1)
      assert assistant_message.role == :assistant
      assert assistant_message.content =~ "```sql"
      assert assistant_message.content =~ "```variables"
      assert assistant_message.content =~ "status"
    end

    test "does not include variables block when variables are empty" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT * FROM users")

      messages = Conversation.build_context_messages(conversation, "System prompt")

      assistant_message = Enum.at(messages, 1)
      refute assistant_message.content =~ "```variables"
    end

    test "builds complete multi-turn conversation" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("Show active users")
        |> Conversation.add_assistant_response(
          "Here's your query:",
          "SELECT * FROM users WHERE status = 'active'"
        )
        |> Conversation.add_query_result({:error, "column 'status' does not exist"})
        |> Conversation.add_user_message("Fix the error")

      messages = Conversation.build_context_messages(conversation, "System prompt")

      assert length(messages) == 5
      assert Enum.at(messages, 0).role == :system
      assert Enum.at(messages, 1).role == :user
      assert Enum.at(messages, 2).role == :assistant
      # Error converted to user message
      assert Enum.at(messages, 3).role == :user
      assert Enum.at(messages, 4).role == :user
    end
  end

  describe "should_auto_retry?/1" do
    test "returns false for empty conversation" do
      conversation = Conversation.new()
      refute Conversation.should_auto_retry?(conversation)
    end

    test "returns false when last message is user message" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("Show users")

      refute Conversation.should_auto_retry?(conversation)
    end

    test "returns false when last message is assistant message" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT * FROM users")

      refute Conversation.should_auto_retry?(conversation)
    end

    test "returns true when last message is error" do
      conversation =
        Conversation.new()
        |> Conversation.add_assistant_response("Query:", "SELECT status FROM users")
        |> Conversation.add_query_result({:error, "column 'status' does not exist"})

      assert Conversation.should_auto_retry?(conversation)
    end
  end

  describe "prune_messages/2" do
    test "keeps all messages when under limit" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("Message 1")
        |> Conversation.add_user_message("Message 2")
        |> Conversation.add_user_message("Message 3")

      pruned = Conversation.prune_messages(conversation, 5)

      assert length(pruned.messages) == 3
    end

    test "prunes to last N messages when over limit" do
      conversation =
        Conversation.new()
        |> Conversation.add_user_message("Message 1")
        |> Conversation.add_user_message("Message 2")
        |> Conversation.add_user_message("Message 3")
        |> Conversation.add_user_message("Message 4")
        |> Conversation.add_user_message("Message 5")

      pruned = Conversation.prune_messages(conversation, 3)

      assert length(pruned.messages) == 3
      assert Enum.at(pruned.messages, 0).content == "Message 3"
      assert Enum.at(pruned.messages, 1).content == "Message 4"
      assert Enum.at(pruned.messages, 2).content == "Message 5"
    end

    test "uses default limit of 10" do
      # Create 15 messages
      conversation =
        Enum.reduce(1..15, Conversation.new(), fn i, conv ->
          Conversation.add_user_message(conv, "Message #{i}")
        end)

      pruned = Conversation.prune_messages(conversation)

      assert length(pruned.messages) == 10
      assert Enum.at(pruned.messages, 0).content == "Message 6"
      assert List.last(pruned.messages).content == "Message 15"
    end
  end

  describe "update_source_context/2" do
    test "adds tables to source context" do
      conversation = Conversation.new()
      conversation = Conversation.update_source_context(conversation, ["users", "orders"])

      assert conversation.source_context.tables_analyzed == ["users", "orders"]
    end

    test "appends tables without duplicates" do
      conversation =
        Conversation.new()
        |> Conversation.update_source_context(["users", "orders"])
        |> Conversation.update_source_context(["orders", "products"])

      assert Enum.sort(conversation.source_context.tables_analyzed) ==
               Enum.sort(["users", "orders", "products"])
    end
  end
end
