defmodule Lotus.VariablesTest do
  use ExUnit.Case, async: true

  alias Lotus.Variables

  describe "regex/0" do
    test "matches valid variable placeholders" do
      assert Regex.match?(Variables.regex(), "{{user_id}}")
      assert Regex.match?(Variables.regex(), "{{_private}}")
      assert Regex.match?(Variables.regex(), "{{Name123}}")
    end

    test "captures variable name without braces" do
      assert [_, "user_id"] = Regex.run(Variables.regex(), "{{user_id}}")
    end

    test "does not match invalid variable names" do
      refute Regex.match?(Variables.regex(), "{{123abc}}")
      refute Regex.match?(Variables.regex(), "{{a-b}}")
      refute Regex.match?(Variables.regex(), "{{}}")
    end
  end

  describe "extract_names/1" do
    test "extracts variable names in order" do
      assert Variables.extract_names("WHERE id = {{user_id}} AND status = {{status}}") ==
               ["user_id", "status"]
    end

    test "preserves duplicate names" do
      assert Variables.extract_names("{{a}} and {{b}} and {{a}}") == ["a", "b", "a"]
    end

    test "returns empty list when no variables" do
      assert Variables.extract_names("SELECT * FROM users") == []
    end

    test "handles variables in complex expressions" do
      content = """
      SELECT * FROM users
      WHERE name ILIKE '%' || {{query}} || '%'
        AND age BETWEEN {{min_age}} AND {{max_age}}
      """

      assert Variables.extract_names(content) == ["query", "min_age", "max_age"]
    end
  end

  describe "neutralize/2" do
    test "replaces variables with NULL" do
      assert Variables.neutralize("WHERE id = {{user_id}}", "NULL") ==
               "WHERE id = NULL"
    end

    test "replaces multiple variables" do
      assert Variables.neutralize("WHERE id = {{id}} AND status = {{status}}", "NULL") ==
               "WHERE id = NULL AND status = NULL"
    end

    test "replaces with empty string" do
      assert Variables.neutralize("Hello {{name}}!", "") == "Hello !"
    end

    test "replaces with custom placeholder" do
      assert Variables.neutralize("{{greeting}} world", "Hello") == "Hello world"
    end

    test "passes through content with no variables" do
      content = "no variables here"
      assert Variables.neutralize(content, "NULL") == content
    end
  end

  describe "extract_names/2 with a profile" do
    alias Lotus.Query.Tokenizer.Profile

    test "ignores a placeholder inside a comment" do
      assert Variables.extract_names("-- {{note}}\nSELECT {{id}}") == ["id"]
    end

    test "ignores a placeholder inside a quoted identifier" do
      assert Variables.extract_names(~S|SELECT "{{col}}" FROM t WHERE id = {{id}}|) == ["id"]
    end

    test "keeps a placeholder inside a string literal" do
      assert Variables.extract_names("WHERE name LIKE '%{{q}}%'") == ["q"]
    end

    test "uses the given profile" do
      mysql = Profile.for_language("sql:mysql")
      assert Variables.extract_names("SELECT 1 # {{c}}\n{{v}}", mysql) == ["v"]
      assert Variables.extract_names("SELECT 1 # {{c}}\n{{v}}") == ["c", "v"]
    end
  end

  describe "neutralize/3 with a profile" do
    alias Lotus.Query.Tokenizer.Profile

    test "leaves a placeholder inside a comment alone" do
      assert Variables.neutralize("-- {{note}}\nSELECT {{id}}", "NULL") ==
               "-- {{note}}\nSELECT NULL"
    end

    test "replaces a placeholder inside a string literal" do
      assert Variables.neutralize("LIKE '%{{q}}%'", "NULL") == "LIKE '%NULL%'"
    end

    test "uses the given profile" do
      mysql = Profile.for_language("sql:mysql")

      assert Variables.neutralize("SELECT `{{i}}`, {{v}}", "NULL", mysql) ==
               "SELECT `{{i}}`, NULL"
    end
  end
end
