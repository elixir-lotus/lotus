defmodule Lotus.Query.TokenizerTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile

  defp sql, do: Profile.for_language("sql")
  defp pg, do: Profile.for_language("sql:postgres")
  defp mysql, do: Profile.for_language("sql:mysql")
  defp json, do: Profile.for_language("json:elasticsearch")

  describe "tokenize/2 code" do
    test "returns plain text as one code token" do
      assert Tokenizer.tokenize("SELECT 1", sql()) == [{:code, "SELECT 1"}]
    end

    test "returns no tokens for an empty string" do
      assert Tokenizer.tokenize("", sql()) == []
    end
  end

  describe "tokenize/2 comments" do
    test "splits a line comment and keeps the newline in code" do
      assert Tokenizer.tokenize("SELECT 1 -- hi\nFROM t", sql()) == [
               {:code, "SELECT 1 "},
               {:comment, "-- hi"},
               {:code, "\nFROM t"}
             ]
    end

    test "runs a line comment to the end of input" do
      assert Tokenizer.tokenize("SELECT 1 -- hi", sql()) == [
               {:code, "SELECT 1 "},
               {:comment, "-- hi"}
             ]
    end

    test "ends a block comment at the first close marker when comments do not nest" do
      assert Tokenizer.tokenize("SELECT 1 /* a /* b */ c */", sql()) == [
               {:code, "SELECT 1 "},
               {:comment, "/* a /* b */"},
               {:code, " c */"}
             ]
    end

    test "tracks depth when the profile nests block comments" do
      assert Tokenizer.tokenize("SELECT 1 /* a /* b */ c */", pg()) == [
               {:code, "SELECT 1 "},
               {:comment, "/* a /* b */ c */"}
             ]
    end

    test "runs an unterminated block comment to the end of input" do
      assert Tokenizer.tokenize("SELECT 1 /* open", sql()) == [
               {:code, "SELECT 1 "},
               {:comment, "/* open"}
             ]
    end

    test "recognizes hash comments when the profile enables them" do
      assert Tokenizer.tokenize("SELECT 1 # note\n", mysql()) == [
               {:code, "SELECT 1 "},
               {:comment, "# note"},
               {:code, "\n"}
             ]
    end

    test "treats a hash as code when the profile does not enable hash comments" do
      assert Tokenizer.tokenize("SELECT 1 # note", sql()) == [{:code, "SELECT 1 # note"}]
    end
  end

  describe "tokenize/2 strings" do
    test "returns a single-quoted literal as one string token including quotes" do
      assert Tokenizer.tokenize("WHERE a = 'x' AND", sql()) == [
               {:code, "WHERE a = "},
               {:string, "'x'"},
               {:code, " AND"}
             ]
    end

    test "keeps a doubled quote inside the literal" do
      assert Tokenizer.tokenize("'O''Brien'", sql()) == [{:string, "'O''Brien'"}]
    end

    test "runs an unterminated literal to the end of input" do
      assert Tokenizer.tokenize("WHERE a = 'open; DROP", sql()) == [
               {:code, "WHERE a = "},
               {:string, "'open; DROP"}
             ]
    end

    test "honours backslash escapes when the profile enables them" do
      assert Tokenizer.tokenize(~S|'a\'b' AND|, mysql()) == [
               {:string, ~S|'a\'b'|},
               {:code, " AND"}
             ]
    end

    test "ignores backslashes when the profile does not enable escapes" do
      assert Tokenizer.tokenize(~S|'a\' AND|, sql()) == [
               {:string, ~S|'a\'|},
               {:code, " AND"}
             ]
    end

    test "treats double quotes as strings when the profile says so" do
      assert Tokenizer.tokenize(~S|WHERE a = "x"|, mysql()) == [
               {:code, "WHERE a = "},
               {:string, ~S|"x"|}
             ]
    end
  end

  describe "tokenize/2 identifiers" do
    test "returns a double-quoted identifier as one identifier token" do
      assert Tokenizer.tokenize(~S|SELECT "my col" FROM t|, sql()) == [
               {:code, "SELECT "},
               {:identifier, ~S|"my col"|},
               {:code, " FROM t"}
             ]
    end

    test "keeps a doubled quote inside the identifier" do
      assert Tokenizer.tokenize(~S|"a""b"|, sql()) == [{:identifier, ~S|"a""b"|}]
    end

    test "returns a backtick identifier when the profile uses backticks" do
      assert Tokenizer.tokenize("SELECT `id` FROM `db`.`t`", mysql()) == [
               {:code, "SELECT "},
               {:identifier, "`id`"},
               {:code, " FROM "},
               {:identifier, "`db`"},
               {:code, "."},
               {:identifier, "`t`"}
             ]
    end

    test "treats a backtick as code when the profile does not use backticks" do
      assert Tokenizer.tokenize("SELECT `id`", sql()) == [{:code, "SELECT `id`"}]
    end
  end

  describe "tokenize/2 dollar quotes" do
    test "returns an untagged dollar-quoted body as one string token" do
      assert Tokenizer.tokenize("SELECT $$a; 'b$$ AS s", pg()) == [
               {:code, "SELECT "},
               {:string, "$$a; 'b$$"},
               {:code, " AS s"}
             ]
    end

    test "returns a tagged dollar-quoted body as one string token" do
      assert Tokenizer.tokenize("SELECT $fn$ $$ ; $fn$", pg()) == [
               {:code, "SELECT "},
               {:string, "$fn$ $$ ; $fn$"}
             ]
    end

    test "leaves a positional parameter as code" do
      assert Tokenizer.tokenize("WHERE id = $1 AND x = $2", pg()) == [
               {:code, "WHERE id = $1 AND x = $2"}
             ]
    end

    test "runs an unterminated dollar quote to the end of input" do
      assert Tokenizer.tokenize("SELECT $$open; DROP", pg()) == [
               {:code, "SELECT "},
               {:string, "$$open; DROP"}
             ]
    end

    test "treats dollar signs as code when the profile disables dollar quotes" do
      assert Tokenizer.tokenize("SELECT $$a$$", mysql()) == [{:code, "SELECT $$a$$"}]
    end
  end

  describe "tokenize/2 variables" do
    test "returns a placeholder as a variable token with its name" do
      assert Tokenizer.tokenize("WHERE id = {{id}}", sql()) == [
               {:code, "WHERE id = "},
               {:variable, "id", "{{id}}"}
             ]
    end

    test "accepts underscores and digits after the first character" do
      assert Tokenizer.tokenize("{{_user_id2}}", sql()) == [
               {:variable, "_user_id2", "{{_user_id2}}"}
             ]
    end

    test "leaves a placeholder with an invalid name as code" do
      assert Tokenizer.tokenize("{{1x}} {{ id }} {{a-b}}", sql()) == [
               {:code, "{{1x}} {{ id }} {{a-b}}"}
             ]
    end

    test "does not recognize a placeholder inside a string literal" do
      assert Tokenizer.tokenize("LIKE '%{{q}}%'", sql()) == [
               {:code, "LIKE "},
               {:string, "'%{{q}}%'"}
             ]
    end

    test "does not recognize a placeholder inside a comment" do
      assert Tokenizer.tokenize("-- {{note}}\nSELECT {{id}}", sql()) == [
               {:comment, "-- {{note}}"},
               {:code, "\nSELECT "},
               {:variable, "id", "{{id}}"}
             ]
    end

    test "does not recognize a placeholder inside a quoted identifier" do
      assert Tokenizer.tokenize(~S|SELECT "{{col}}"|, sql()) == [
               {:code, "SELECT "},
               {:identifier, ~S|"{{col}}"|}
             ]
    end
  end

  describe "tokenize/2 optional blocks" do
    test "returns a bracket block with its inner tokens" do
      assert Tokenizer.tokenize("WHERE 1=1 [[AND a = {{a}}]]", sql()) == [
               {:code, "WHERE 1=1 "},
               {:block, [{:code, "AND a = "}, {:variable, "a", "{{a}}"}]}
             ]
    end

    test "nests blocks" do
      assert Tokenizer.tokenize("[[a [[b]] c]]", sql()) == [
               {:block, [{:code, "a "}, {:block, [{:code, "b"}]}, {:code, " c"}]}
             ]
    end

    test "tokenizes strings and comments inside a block" do
      assert Tokenizer.tokenize("[[AND x = 'a]]b' -- ]]\n]]", sql()) == [
               {:block,
                [
                  {:code, "AND x = "},
                  {:string, "'a]]b'"},
                  {:code, " "},
                  {:comment, "-- ]]"},
                  {:code, "\n"}
                ]}
             ]
    end

    test "leaves an unclosed opening bracket as code" do
      assert Tokenizer.tokenize("WHERE 1=1 [[AND a = {{a}}", sql()) == [
               {:code, "WHERE 1=1 [[AND a = "},
               {:variable, "a", "{{a}}"}
             ]
    end

    test "leaves a stray closing bracket as code" do
      assert Tokenizer.tokenize("a ]] b", sql()) == [{:code, "a ]] b"}]
    end

    test "does not recognize a block inside a string literal" do
      assert Tokenizer.tokenize("SELECT '[[x]]'", sql()) == [
               {:code, "SELECT "},
               {:string, "'[[x]]'"}
             ]
    end

    test "leaves an empty block as an empty block" do
      assert Tokenizer.tokenize("[[]]", sql()) == [{:block, []}]
    end
  end

  describe "tokenize/2 with a json profile" do
    test "treats double quotes as strings with backslash escapes" do
      assert Tokenizer.tokenize(~S|{"q": "a\"[[b", "n": {{n}}}|, json()) == [
               {:code, "{"},
               {:string, ~S|"q"|},
               {:code, ": "},
               {:string, ~S|"a\"[[b"|},
               {:code, ", "},
               {:string, ~S|"n"|},
               {:code, ": "},
               {:variable, "n", "{{n}}"},
               {:code, "}"}
             ]
    end

    test "has no comment syntax" do
      assert Tokenizer.tokenize("-- /* # //", json()) == [{:code, "-- /* # //"}]
    end

    test "treats single quotes as code" do
      assert Tokenizer.tokenize("'a' {{v}}", json()) == [
               {:code, "'a' "},
               {:variable, "v", "{{v}}"}
             ]
    end
  end

  describe "to_string/1" do
    @round_trips [
      {"sql", "SELECT 1"},
      {"sql", ""},
      {"sql", "SELECT 'a''b', \"c\"\"d\" -- x\n/* y */ [[AND a = {{a}} [[b]]]] ]] [[ {{1x}}"},
      {"sql:postgres", "SELECT $$a$$, $t$b$t$, $1 /* a /* b */ c */ '{{x}}' {{y}}"},
      {"sql:mysql", "SELECT `a`, \"s\", 'a\\'b' # c\n/* a /* b */ c */ {{v}}"},
      {"sql:sqlite", "SELECT \"a\", `b`, [[AND x = {{x}}]] 'y'"},
      {"json:elasticsearch", ~S|{"q": "a\"b", "n": {{n}}, "o": [[{{o}}]]}|},
      {"sql", "unterminated 'string"},
      {"sql", "unterminated /* comment"},
      {"sql:postgres", "unterminated $$dollar"}
    ]

    for {language, input} <- @round_trips do
      test "round-trips #{inspect(input)} under #{language}" do
        profile = Profile.for_language(unquote(language))
        tokens = Tokenizer.tokenize(unquote(input), profile)
        assert Tokenizer.to_string(tokens) == unquote(input)
      end
    end
  end
end
