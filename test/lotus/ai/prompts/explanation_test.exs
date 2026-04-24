defmodule Lotus.AI.Prompts.ExplanationTest do
  use ExUnit.Case, async: true

  alias Lotus.AI.Prompts.Explanation

  describe "system_prompt/1" do
    test "includes database type" do
      prompt = Explanation.system_prompt(:postgres)
      assert prompt =~ "postgres"
    end

    test "instructs to explain, not optimize" do
      prompt = Explanation.system_prompt(:postgres)
      assert prompt =~ "explain"
      assert prompt =~ "Do NOT suggest improvements"
    end

    test "works for different database types" do
      for db <- [:postgres, :mysql, :sqlite] do
        prompt = Explanation.system_prompt(db)
        assert prompt =~ to_string(db)
      end
    end

    test "documents Lotus variable syntax {{...}}" do
      prompt = Explanation.system_prompt(:postgres)
      assert prompt =~ "{{variable_name}}"
      assert prompt =~ "variable placeholder"
    end

    test "documents Lotus optional clause syntax [[...]]" do
      prompt = Explanation.system_prompt(:postgres)
      assert prompt =~ "[[...]]"
      assert prompt =~ "Optional clause"
    end

    test "documents list variable expansion" do
      prompt = Explanation.system_prompt(:postgres)
      assert prompt =~ "list"
      assert prompt =~ "comma-separated"
    end
  end

  describe "user_prompt/2" do
    test "includes the SQL query" do
      prompt = Explanation.user_prompt("SELECT * FROM users", nil)
      assert prompt =~ "SELECT * FROM users"
      assert prompt =~ "Explain what this SQL query does"
    end

    test "includes source context when provided" do
      prompt = Explanation.user_prompt("SELECT * FROM users", "users: id, name, email")
      assert prompt =~ "## Source Context"
      assert prompt =~ "users: id, name, email"
    end

    test "omits source context when nil" do
      prompt = Explanation.user_prompt("SELECT * FROM users", nil)
      refute prompt =~ "## Source Context"
    end
  end

  describe "fragment_prompt/3" do
    test "includes both fragment and full query" do
      fragment = "LEFT JOIN orders o ON o.user_id = u.id"
      full_sql = "SELECT u.name FROM users u LEFT JOIN orders o ON o.user_id = u.id"

      prompt = Explanation.fragment_prompt(fragment, full_sql)
      assert prompt =~ "## Selected Fragment"
      assert prompt =~ fragment
      assert prompt =~ "## Full Query (for context)"
      assert prompt =~ full_sql
    end

    test "instructs to explain the fragment in context" do
      prompt = Explanation.fragment_prompt("HAVING SUM(o.total) > 10000", "SELECT ...")
      assert prompt =~ "selected fragment"
      assert prompt =~ "context"
    end

    test "includes source context when provided" do
      prompt =
        Explanation.fragment_prompt("JOIN orders", "SELECT ...", "orders: id, total, user_id")

      assert prompt =~ "## Source Context"
      assert prompt =~ "orders: id, total, user_id"
    end

    test "omits source context when nil" do
      prompt = Explanation.fragment_prompt("JOIN orders", "SELECT ...", nil)
      refute prompt =~ "## Source Context"
    end
  end
end
