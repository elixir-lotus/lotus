defmodule Lotus.Query.Tokenizer.ProfileTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Tokenizer.Profile

  describe "for_language/1" do
    test "returns ANSI SQL rules for a bare sql language" do
      assert %Profile{
               string_quotes: ["'"],
               identifier_quotes: ["\""],
               line_comments: ["--"],
               block_comments?: true,
               nested_block_comments?: false,
               dollar_quotes?: false,
               backslash_escapes?: false
             } = Profile.for_language("sql")
    end

    test "enables dollar quotes and nested comments for postgres" do
      profile = Profile.for_language("sql:postgres")
      assert profile.dollar_quotes?
      assert profile.nested_block_comments?
      assert profile.identifier_quotes == ["\""]
    end

    test "uses backticks, hash comments, backslash escapes and double-quoted strings for mysql" do
      assert %Profile{
               string_quotes: ["'", "\""],
               identifier_quotes: ["`"],
               line_comments: ["--", "#"],
               nested_block_comments?: false,
               dollar_quotes?: false,
               backslash_escapes?: true
             } = Profile.for_language("sql:mysql")
    end

    test "accepts double quotes and backticks as identifiers for sqlite" do
      assert %Profile{
               string_quotes: ["'"],
               identifier_quotes: ["\"", "`"],
               line_comments: ["--"],
               nested_block_comments?: false,
               dollar_quotes?: false,
               backslash_escapes?: false
             } = Profile.for_language("sql:sqlite")
    end

    test "uses json string rules and no comments for a json language" do
      assert %Profile{
               string_quotes: ["\""],
               identifier_quotes: [],
               line_comments: [],
               block_comments?: false,
               dollar_quotes?: false,
               backslash_escapes?: true
             } = Profile.for_language("json:elasticsearch")
    end

    test "falls back to ANSI SQL for an unknown language" do
      assert Profile.for_language("cypher:neo4j") == Profile.for_language("sql")
      assert Profile.for_language("sql:clickhouse") == Profile.for_language("sql")
    end

    test "falls back to ANSI SQL for nil" do
      assert Profile.for_language(nil) == Profile.for_language("sql")
    end
  end

  describe "from_dialect_spec/2" do
    test "returns the base profile unchanged for an empty spec" do
      base = Profile.for_language("sql")
      assert Profile.from_dialect_spec(base, %{}) == base
    end

    test "replaces identifier quotes from the spec" do
      profile = Profile.from_dialect_spec(Profile.for_language("sql"), %{identifier_quotes: "`"})
      assert profile.identifier_quotes == ["`"]
    end

    test "splits a multi-character identifier quote spec into one quote per character" do
      profile =
        Profile.from_dialect_spec(Profile.for_language("sql"), %{identifier_quotes: "`\""})

      assert profile.identifier_quotes == ["`", "\""]
    end

    test "adds hash and slash line comments" do
      profile =
        Profile.from_dialect_spec(Profile.for_language("sql"), %{
          hash_comments: true,
          slash_comments: true
        })

      assert profile.line_comments == ["--", "#", "//"]
    end

    test "removes hash comments when the spec disables them" do
      profile =
        Profile.from_dialect_spec(Profile.for_language("sql:mysql"), %{hash_comments: false})

      assert profile.line_comments == ["--"]
    end

    test "adds double quotes as strings and drops them as identifiers" do
      profile =
        Profile.from_dialect_spec(Profile.for_language("sql"), %{double_quoted_strings: true})

      assert profile.string_quotes == ["'", "\""]
      assert profile.identifier_quotes == []
    end

    test "enables dollar quotes and backslash escapes" do
      profile =
        Profile.from_dialect_spec(Profile.for_language("sql"), %{
          double_dollar_quoted_strings: true,
          backslash_escapes: true
        })

      assert profile.dollar_quotes?
      assert profile.backslash_escapes?
    end

    test "ignores keys it does not understand" do
      base = Profile.for_language("sql")
      assert Profile.from_dialect_spec(base, %{operator_chars: "+-", builtin: "x"}) == base
    end

    test "accepts a nil spec" do
      base = Profile.for_language("sql")
      assert Profile.from_dialect_spec(base, nil) == base
    end
  end
end
