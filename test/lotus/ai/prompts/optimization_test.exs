defmodule Lotus.AI.Prompts.OptimizationTest do
  use ExUnit.Case, async: true

  alias Lotus.AI.Prompts.Optimization

  defp pg_context do
    %{
      language: "sql:postgres",
      syntax_notes: "Postgres uses EXPLAIN (FORMAT JSON). Look for Seq Scan in the plan.",
      example_query: "SELECT * FROM users LIMIT 10",
      error_patterns: []
    }
  end

  describe "system_prompt/1" do
    test "includes the language identifier" do
      prompt = Optimization.system_prompt(pg_context())
      assert prompt =~ "sql:postgres"
    end

    test "emits adapter-supplied syntax_notes" do
      prompt = Optimization.system_prompt(pg_context())
      assert prompt =~ "Seq Scan"
      assert prompt =~ "EXPLAIN (FORMAT JSON)"
    end

    test "describes expected response format" do
      prompt = Optimization.system_prompt(pg_context())
      assert prompt =~ "type"
      assert prompt =~ "impact"
      assert prompt =~ "suggestion"
    end
  end

  describe "user_prompt/3" do
    test "includes SQL query" do
      prompt = Optimization.user_prompt("SELECT * FROM users", nil)
      assert prompt =~ "SELECT * FROM users"
      assert prompt =~ "## SQL Query"
    end

    test "includes execution plan when provided" do
      plan = ~s({"Node Type": "Seq Scan"})
      prompt = Optimization.user_prompt("SELECT * FROM users", plan)
      assert prompt =~ "## Execution Plan"
      assert prompt =~ "Seq Scan"
    end

    test "omits execution plan section when nil" do
      prompt = Optimization.user_prompt("SELECT * FROM users", nil)
      refute prompt =~ "## Execution Plan"
    end

    test "includes source context when provided" do
      prompt = Optimization.user_prompt("SELECT * FROM users", nil, "users: id, name, email")
      assert prompt =~ "## Source Context"
      assert prompt =~ "users: id, name, email"
    end

    test "omits source context when nil" do
      prompt = Optimization.user_prompt("SELECT * FROM users", nil, nil)
      refute prompt =~ "## Source Context"
    end
  end

  describe "parse_suggestions/1" do
    test "parses valid JSON array of suggestions" do
      content = """
      ```json
      [
        {
          "type": "index",
          "impact": "high",
          "title": "Add index on orders.created_at",
          "suggestion": "Create an index to avoid sequential scan."
        }
      ]
      ```
      """

      suggestions = Optimization.parse_suggestions(content)
      assert length(suggestions) == 1

      [suggestion] = suggestions
      assert suggestion["type"] == "index"
      assert suggestion["impact"] == "high"
      assert suggestion["title"] == "Add index on orders.created_at"
      assert suggestion["suggestion"] =~ "sequential scan"
    end

    test "parses plain JSON without markdown wrapper" do
      content =
        ~s([{"type": "rewrite", "impact": "low", "title": "Use LIMIT", "suggestion": "Add a LIMIT clause."}])

      suggestions = Optimization.parse_suggestions(content)
      assert length(suggestions) == 1
      assert hd(suggestions)["type"] == "rewrite"
    end

    test "returns empty list for empty array" do
      assert Optimization.parse_suggestions("[]") == []
    end

    test "returns empty list for invalid JSON" do
      assert Optimization.parse_suggestions("not json at all") == []
    end

    test "filters out invalid suggestion objects" do
      content = ~s([{"type": "index", "suggestion": "valid"}, {"invalid": true}, "not a map"])

      suggestions = Optimization.parse_suggestions(content)
      assert length(suggestions) == 1
    end

    test "normalizes unknown types to rewrite" do
      content = ~s([{"type": "unknown_type", "suggestion": "some suggestion"}])

      [suggestion] = Optimization.parse_suggestions(content)
      assert suggestion["type"] == "rewrite"
    end

    test "normalizes unknown impacts to medium" do
      content = ~s([{"type": "index", "impact": "critical", "suggestion": "some suggestion"}])

      [suggestion] = Optimization.parse_suggestions(content)
      assert suggestion["impact"] == "medium"
    end

    test "generates title from suggestion when missing" do
      content = ~s([{"type": "index", "suggestion": "Add an index on the created_at column."}])

      [suggestion] = Optimization.parse_suggestions(content)
      assert suggestion["title"] == "Add an index on the created_at column."
    end
  end
end
