defmodule Lotus.Query.Tokenizer.DialectsTest do
  @moduledoc """
  One test per lexical rule of `Lotus.Query.Tokenizer`, per dialect,
  including the cases the byte-level rewrite fixed.
  """

  use ExUnit.Case, async: true

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile

  defp sql, do: Profile.for_language("sql")
  defp pg, do: Profile.for_language("sql:postgres")
  defp mysql, do: Profile.for_language("sql:mysql")
  defp sqlite, do: Profile.for_language("sql:sqlite")

  defp tokenize(text, profile) do
    tokens = Tokenizer.tokenize(text, profile)
    assert Tokenizer.to_string(tokens) == text
    tokens
  end

  defp code(text, profile), do: text |> tokenize(profile) |> Tokenizer.code() |> Enum.join()

  describe "postgres escape strings" do
    test "a backslash-escaped quote does not end an E'' string" do
      assert tokenize("SELECT E'it\\'s; {{x}}' AS s", pg()) == [
               {:code, "SELECT E"},
               {:string, "'it\\'s; {{x}}'"},
               {:code, " AS s"}
             ]
    end

    test "the semicolon and placeholder inside stay out of code" do
      tokens = tokenize("SELECT E'it\\'s; {{x}}'", pg())
      refute tokens |> Tokenizer.code() |> Enum.join() |> String.contains?(";")
      assert Tokenizer.variables(tokens) == ["x"]
    end

    test "accepts a lowercase prefix" do
      assert tokenize("e'a\\'b' x", pg()) == [
               {:code, "e"},
               {:string, "'a\\'b'"},
               {:code, " x"}
             ]
    end

    test "an escaped backslash leaves the next quote closing" do
      assert tokenize("E'a\\\\' || 'b'", pg()) == [
               {:code, "E"},
               {:string, "'a\\\\'"},
               {:code, " || "},
               {:string, "'b'"}
             ]
    end

    test "a doubled quote still stays inside" do
      assert tokenize("E'a''b'", pg()) == [{:code, "E"}, {:string, "'a''b'"}]
    end

    test "follows punctuation" do
      assert tokenize("(E'\\'')", pg()) == [{:code, "(E"}, {:string, "'\\''"}, {:code, ")"}]
    end

    test "an E that ends an identifier is not a prefix" do
      assert tokenize("SELECT nameE'a\\' , 1", pg()) == [
               {:code, "SELECT nameE"},
               {:string, "'a\\'"},
               {:code, " , 1"}
             ]
    end

    test "an E after a digit or a dollar is not a prefix" do
      assert tokenize("1E'a\\' x", pg()) == [{:code, "1E"}, {:string, "'a\\'"}, {:code, " x"}]
      assert tokenize("$E'a\\' x", pg()) == [{:code, "$E"}, {:string, "'a\\'"}, {:code, " x"}]
    end

    test "plain strings take no backslash escapes" do
      assert tokenize("'a\\' , 'b'", pg()) == [
               {:string, "'a\\'"},
               {:code, " , "},
               {:string, "'b'"}
             ]
    end

    test "only postgres reads the E prefix" do
      assert tokenize("E'a\\' x", sql()) == [{:code, "E"}, {:string, "'a\\'"}, {:code, " x"}]
      assert tokenize("E'a\\' x", sqlite()) == [{:code, "E"}, {:string, "'a\\'"}, {:code, " x"}]
    end

    test "U&, N, X and B prefixes are ordinary strings" do
      assert tokenize("U&'d\\0061t\\' , N'a', X'1F', B'01'", pg()) == [
               {:code, "U&"},
               {:string, "'d\\0061t\\'"},
               {:code, " , N"},
               {:string, "'a'"},
               {:code, ", X"},
               {:string, "'1F'"},
               {:code, ", B"},
               {:string, "'01'"}
             ]
    end

    test "a U& identifier keeps its prefix in code" do
      assert tokenize(~S|SELECT U&"d\0061t"|, pg()) == [
               {:code, "SELECT U&"},
               {:identifier, ~S|"d\0061t"|}
             ]
    end
  end

  describe "postgres dollar quotes" do
    test "a dollar quote cannot start inside an identifier" do
      assert tokenize("SELECT foo$bar$ FROM t WHERE a = $1", pg()) == [
               {:code, "SELECT foo$bar$ FROM t WHERE a = $1"}
             ]
    end

    test "nor right after a digit, an underscore or a dollar" do
      assert tokenize("x1$$a$$ x_$$a$$ $$$a$$", pg()) == [
               {:code, "x1$$a$$ x_$$a$$ "},
               {:string, "$$$a$$"}
             ]
    end

    test "starts after punctuation and whitespace" do
      assert tokenize("x=$$a$$,($t$b$t$)", pg()) == [
               {:code, "x="},
               {:string, "$$a$$"},
               {:code, ",("},
               {:string, "$t$b$t$"},
               {:code, ")"}
             ]
    end

    test "a tag may hold digits after its first byte and non-ASCII bytes" do
      assert tokenize("$t1$ a $t1$ $é$ b $é$ $_$ c $_$", pg()) == [
               {:string, "$t1$ a $t1$"},
               {:code, " "},
               {:string, "$é$ b $é$"},
               {:code, " "},
               {:string, "$_$ c $_$"}
             ]
    end

    test "a tag cannot start with a digit" do
      assert tokenize("$1$ x", pg()) == [{:code, "$1$ x"}]
    end

    test "a different tag inside the body does not close it" do
      assert tokenize("$a$ $b$ $$ ; {{x}} $a$", pg()) == [{:string, "$a$ $b$ $$ ; {{x}} $a$"}]
    end

    test "the closing delimiter may follow identifier bytes" do
      assert tokenize("$a$x$a$ y", pg()) == [{:string, "$a$x$a$"}, {:code, " y"}]
    end

    test "positional parameters stay code" do
      assert tokenize("WHERE a = $1 AND b = $23", pg()) == [{:code, "WHERE a = $1 AND b = $23"}]
    end

    test "a lone dollar at the end is code" do
      assert tokenize("x $", pg()) == [{:code, "x $"}]
    end
  end

  describe "postgres comments" do
    test "a carriage return ends a line comment" do
      assert tokenize("-- a\rDROP TABLE t", pg()) == [
               {:comment, "-- a"},
               {:code, "\rDROP TABLE t"}
             ]
    end

    test "CRLF leaves the line break in code" do
      assert tokenize("-- a\r\nx", pg()) == [{:comment, "-- a"}, {:code, "\r\nx"}]
    end

    test "other dialects end line comments at the line feed only" do
      assert tokenize("-- a\r\nx", sql()) == [{:comment, "-- a\r"}, {:code, "\nx"}]
      assert tokenize("# a\r\nx", mysql()) == [{:comment, "# a\r"}, {:code, "\nx"}]
    end

    test "-- always starts a comment, even between digits" do
      assert tokenize("SELECT 5--1\n", pg()) == [
               {:code, "SELECT 5"},
               {:comment, "--1"},
               {:code, "\n"}
             ]
    end

    test "block comments nest" do
      assert tokenize("/* a /* b */ c */ x", pg()) == [
               {:comment, "/* a /* b */ c */"},
               {:code, " x"}
             ]
    end

    test "the star of the opener does not start a nested opener" do
      assert tokenize("/*/ a */ b */ c", pg()) == [{:comment, "/*/ a */"}, {:code, " b */ c"}]
    end

    test "an unterminated nested comment runs to the end" do
      assert tokenize("/* a /* b */", pg()) == [{:comment, "/* a /* b */"}]
    end
  end

  describe "mysql comments" do
    test "-- needs whitespace or a control character after it" do
      assert tokenize("SELECT 5--1", mysql()) == [{:code, "SELECT 5--1"}]
      assert code("SELECT 5--1", mysql()) == "SELECT 5--1"
    end

    test "-- followed by a space, a tab or a newline is a comment" do
      assert tokenize("a -- x\nb", mysql()) == [{:code, "a "}, {:comment, "-- x"}, {:code, "\nb"}]
      assert tokenize("a --\tx", mysql()) == [{:code, "a "}, {:comment, "--\tx"}]
      assert tokenize("a --\nb", mysql()) == [{:code, "a "}, {:comment, "--"}, {:code, "\nb"}]
    end

    test "-- followed by another control character is a comment" do
      assert tokenize("a --\x01x", mysql()) == [{:code, "a "}, {:comment, "--\x01x"}]
    end

    test "-- at the end of input is a comment" do
      assert tokenize("a --", mysql()) == [{:code, "a "}, {:comment, "--"}]
    end

    test "a third dash can start the comment" do
      assert tokenize("SELECT 1 --- x", mysql()) == [
               {:code, "SELECT 1 -"},
               {:comment, "-- x"}
             ]
    end

    test "a placeholder after a non-comment -- is recognized" do
      assert tokenize("5--{{x}}", mysql()) == [{:code, "5--"}, {:variable, "x", "{{x}}"}]
    end

    test "hash comments run to the line feed" do
      assert tokenize("a # x; y\nb", mysql()) == [
               {:code, "a "},
               {:comment, "# x; y"},
               {:code, "\nb"}
             ]
    end

    test "executable comments are code" do
      text = "SELECT 1 /*!50000 ; DROP TABLE t */"

      assert tokenize(text, mysql()) == [{:code, text}]
      assert code(text, mysql()) =~ "DROP TABLE t"
      assert code(text, mysql()) =~ ";"
    end

    test "executable comments without a version and MariaDB's /*M! are code" do
      assert tokenize("/*! STRAIGHT_JOIN */ x", mysql()) == [{:code, "/*! STRAIGHT_JOIN */ x"}]
      assert tokenize("/*M!100100 x */", mysql()) == [{:code, "/*M!100100 x */"}]
    end

    test "regions inside an executable comment are tokenized" do
      assert tokenize("/*! 'a;b' {{v}} */", mysql()) == [
               {:code, "/*! "},
               {:string, "'a;b'"},
               {:code, " "},
               {:variable, "v", "{{v}}"},
               {:code, " */"}
             ]
    end

    test "optimizer hints stay comments" do
      assert tokenize("SELECT /*+ BKA(t) */ 1", mysql()) == [
               {:code, "SELECT "},
               {:comment, "/*+ BKA(t) */"},
               {:code, " 1"}
             ]
    end

    test "plain block comments are comments and do not nest" do
      assert tokenize("/* a /* b */ c", mysql()) == [{:comment, "/* a /* b */"}, {:code, " c"}]
    end

    test "other dialects keep /*! as a comment" do
      assert tokenize("/*! x */", pg()) == [{:comment, "/*! x */"}]
      assert tokenize("/*! x */", sqlite()) == [{:comment, "/*! x */"}]
    end

    test "other dialects treat -- before a digit as a comment" do
      assert tokenize("5--1", sql()) == [{:code, "5"}, {:comment, "--1"}]
      assert tokenize("5--1", sqlite()) == [{:code, "5"}, {:comment, "--1"}]
    end
  end

  describe "mysql strings and identifiers" do
    test "single and double quoted strings take backslash escapes and doubled quotes" do
      assert tokenize(~S|'a\'b' "c\"d" 'e''f' "g""h"|, mysql()) == [
               {:string, ~S|'a\'b'|},
               {:code, " "},
               {:string, ~S|"c\"d"|},
               {:code, " "},
               {:string, "'e''f'"},
               {:code, " "},
               {:string, ~S|"g""h"|}
             ]
    end

    test "an escaped backslash before the quote closes the string" do
      assert tokenize(~S|'a\\' x|, mysql()) == [{:string, ~S|'a\\'|}, {:code, " x"}]
    end

    test "a trailing backslash runs to the end" do
      assert tokenize("'a\\", mysql()) == [{:string, "'a\\"}]
    end

    test "backtick identifiers double their backticks and take no escapes" do
      assert tokenize("`a``b` `c\\` x", mysql()) == [
               {:identifier, "`a``b`"},
               {:code, " "},
               {:identifier, "`c\\`"},
               {:code, " x"}
             ]
    end

    test "introducers stay in code" do
      assert tokenize("_utf8mb4'x' N'y'", mysql()) == [
               {:code, "_utf8mb4"},
               {:string, "'x'"},
               {:code, " N"},
               {:string, "'y'"}
             ]
    end
  end

  describe "sqlite identifiers" do
    test "brackets quote an identifier" do
      assert tokenize("SELECT [my col] FROM t", sqlite()) == [
               {:code, "SELECT "},
               {:identifier, "[my col]"},
               {:code, " FROM t"}
             ]
    end

    test "the first ] closes it, with no escapes" do
      assert tokenize("[a--b]] x", sqlite()) == [
               {:identifier, "[a--b]"},
               {:code, "] x"}
             ]
    end

    test "placeholders inside are not recognized" do
      tokens = tokenize("[{{x}}]", sqlite())
      assert tokens == [{:identifier, "[{{x}}]"}]
      assert Tokenizer.variables(tokens) == []
    end

    test "an unterminated one runs to the end" do
      assert tokenize("SELECT [a; DROP", sqlite()) == [
               {:code, "SELECT "},
               {:identifier, "[a; DROP"}
             ]
    end

    test "[[ opens a Lotus block before a bracket identifier" do
      assert tokenize("WHERE 1=1 [[AND [x] = {{x}}]]", sqlite()) == [
               {:code, "WHERE 1=1 "},
               {:block,
                [
                  {:code, "AND "},
                  {:identifier, "[x]"},
                  {:code, " = "},
                  {:variable, "x", "{{x}}"}
                ]}
             ]
    end

    test "[[ that cannot open a block starts a bracket identifier" do
      assert tokenize("x[[y] z", sqlite()) == [{:code, "x"}, {:identifier, "[[y]"}, {:code, " z"}]
    end

    test "an unclosed [[ is code, not a bracket identifier" do
      assert tokenize("a [[b", sqlite()) == [{:code, "a [[b"}]
    end

    test "double quotes and backticks quote identifiers" do
      assert tokenize(~S|"a""b" `c``d`|, sqlite()) == [
               {:identifier, ~S|"a""b"|},
               {:code, " "},
               {:identifier, "`c``d`"}
             ]
    end

    test "strings take no backslash escapes" do
      assert tokenize(~S|'a\' x|, sqlite()) == [{:string, ~S|'a\'|}, {:code, " x"}]
    end

    test "other dialects treat [ as code" do
      assert tokenize("SELECT [a] FROM t", pg()) == [{:code, "SELECT [a] FROM t"}]
      assert tokenize("SELECT [a] FROM t", mysql()) == [{:code, "SELECT [a] FROM t"}]
    end
  end

  describe "arrays and optional blocks" do
    test "a nested array constructor is code" do
      assert tokenize("SELECT ARRAY[[1,2],[3,4]]", pg()) == [{:code, "SELECT ARRAY[[1,2],[3,4]]"}]
    end

    test "ARRAY in any case and with whitespace before [[" do
      for text <- ["array[[1]]", "ARRAY [[1]]", "Array\n\t[[1]]", "x(ARRAY [[1,2]])"] do
        assert tokenize(text, pg()) == [{:code, text}]
      end
    end

    test "deeper arrays are code" do
      assert tokenize("ARRAY[[[1]],[[2]]]", pg()) == [{:code, "ARRAY[[[1]],[[2]]]"}]
    end

    test "subscripts are code" do
      for text <- ["arr[1][2]", "x[y[1]]", "a[b[c[1]]] = 1", "m[1:2][3]"] do
        assert tokenize(text, pg()) == [{:code, text}]
      end
    end

    test "[[ right after an identifier is code" do
      assert tokenize("WHERE active[[AND x]]", pg()) == [{:code, "WHERE active[[AND x]]"}]
      assert tokenize("1=1[[AND x]]", pg()) == [{:code, "1=1[[AND x]]"}]
    end

    test "a word that ends in array is not the keyword" do
      assert tokenize("my_array [[AND x]]", pg()) == [
               {:code, "my_array "},
               {:block, [{:code, "AND x"}]}
             ]
    end

    test "a block may follow punctuation, a placeholder or another block" do
      assert tokenize("(a)[[x]][[y]]{{v}}[[z]]", pg()) == [
               {:code, "(a)"},
               {:block, [{:code, "x"}]},
               {:block, [{:code, "y"}]},
               {:variable, "v", "{{v}}"},
               {:block, [{:code, "z"}]}
             ]
    end

    test "a subscript inside a block closes before the block" do
      assert tokenize("WHERE 1=1 [[AND x = arr[y[1]]]]", pg()) == [
               {:code, "WHERE 1=1 "},
               {:block, [{:code, "AND x = arr[y[1]]"}]}
             ]
    end

    test "an array constructor inside a block" do
      assert tokenize("[[AND a @> ARRAY[[1,2]]]] b", pg()) == [
               {:block, [{:code, "AND a @> ARRAY[[1,2]]"}]},
               {:code, " b"}
             ]
    end

    test "nested blocks without spaces" do
      assert tokenize("[[[[a]]]]", pg()) == [{:block, [{:block, [{:code, "a"}]}]}]
    end

    test "]] closes only an open block" do
      assert tokenize("a ]] b [[c]]]]", pg()) == [
               {:code, "a ]] b "},
               {:block, [{:code, "c"}]},
               {:code, "]]"}
             ]
    end

    test "a single [ left open in a block keeps the block open" do
      assert tokenize("[[a [ b]] c", pg()) == [{:code, "[[a [ b]] c"}]
    end

    test "blocks inside an unclosed block are kept" do
      assert tokenize("[[a [[b]] c", pg()) == [
               {:code, "[[a "},
               {:block, [{:code, "b"}]},
               {:code, " c"}
             ]
    end

    test "unclosed blocks inside unclosed blocks are all code" do
      assert tokenize("[[a [[b [[c]] d", pg()) == [
               {:code, "[[a [[b "},
               {:block, [{:code, "c"}]},
               {:code, " d"}
             ]
    end

    test "brackets in strings and comments do not count" do
      assert tokenize("[[AND x = '[' -- [\n]]", pg()) == [
               {:block,
                [
                  {:code, "AND x = "},
                  {:string, "'['"},
                  {:code, " "},
                  {:comment, "-- ["},
                  {:code, "\n"}
                ]}
             ]
    end
  end

  describe "ANSI and shared rules" do
    test "a line comment at the end of input needs no newline" do
      assert tokenize("x -- {{a}}", sql()) == [{:code, "x "}, {:comment, "-- {{a}}"}]
    end

    test "unterminated regions run to the end" do
      assert tokenize("x 'a", sql()) == [{:code, "x "}, {:string, "'a"}]
      assert tokenize(~S|x "a|, sql()) == [{:code, "x "}, {:identifier, ~S|"a|}]
      assert tokenize("x /* a", sql()) == [{:code, "x "}, {:comment, "/* a"}]
      assert tokenize("x $a$ b", pg()) == [{:code, "x "}, {:string, "$a$ b"}]
    end

    test "a doubled quote at the end of input is inside the string" do
      assert tokenize("'a''", sql()) == [{:string, "'a''"}]
    end

    test "a placeholder needs a valid name and closing braces" do
      assert tokenize("{{a {{1}} {{a-b}} {{_}}", sql()) == [
               {:code, "{{a {{1}} {{a-b}} "},
               {:variable, "_", "{{_}}"}
             ]
    end

    test "a failed placeholder resumes after its braces" do
      assert tokenize("{{{a}}", sql()) == [{:code, "{{{a}}"}]
      assert tokenize("{{ 'x' }}", sql()) == [{:code, "{{ "}, {:string, "'x'"}, {:code, " }}"}]
    end

    test "non-ASCII text passes through" do
      assert tokenize("SELECT 'ünï' AS \"çø\" -- ☃\n{{v}}", sql()) == [
               {:code, "SELECT "},
               {:string, "'ünï'"},
               {:code, " AS "},
               {:identifier, ~S|"çø"|},
               {:code, " "},
               {:comment, "-- ☃"},
               {:code, "\n"},
               {:variable, "v", "{{v}}"}
             ]
    end

    test "invalid UTF-8 does not raise" do
      text = <<"SELECT '", 0xFF, "' ", 0xC3, " -- ", 0x80, "\n", 0xE2, 0x82>>
      assert text |> tokenize(pg()) |> Tokenizer.to_string() == text
    end
  end

  describe "placeholders inside strings" do
    test "the leftmost placeholder wins, as with a regex scan" do
      tokens = tokenize("'{{{a}}} {{b}}{{c}} {{1x}} {{ d }}'", sql())
      assert Tokenizer.variables(tokens) == ["a", "b", "c"]
    end

    test "replace_variables rewrites every placeholder in a string" do
      tokens = tokenize("x = '{{{a}}}-{{b}}' AND y = {{a}}", sql())

      assert tokens
             |> Tokenizer.replace_variables(&String.upcase/1)
             |> Tokenizer.to_string() == "x = '{A}-B' AND y = A"
    end

    test "a string without placeholders is left alone" do
      tokens = tokenize("'{{ x }}'", sql())
      assert Tokenizer.replace_variables(tokens, fn _ -> "y" end) == tokens
    end
  end

  describe "hand-built profiles" do
    test "multi-byte quotes and comment markers use the generic scanner" do
      profile = %Profile{
        string_quotes: ["''"],
        identifier_quotes: ["«"],
        line_comments: ["REM"],
        block_comments?: false
      }

      assert tokenize("a ''x'' «y« REM z\n{{v}}", profile) == [
               {:code, "a "},
               {:string, "''x''"},
               {:code, " "},
               {:identifier, "«y«"},
               {:code, " "},
               {:comment, "REM z"},
               {:code, "\n"},
               {:variable, "v", "{{v}}"}
             ]
    end

    test "[ among identifier quotes means bracket identifiers" do
      profile = Profile.from_dialect_spec(Profile.for_language("sql"), %{identifier_quotes: "["})
      assert tokenize("SELECT [a b]", profile) == [{:code, "SELECT "}, {:identifier, "[a b]"}]
    end
  end

  describe "size" do
    test "a 10 MB input with a 5 MB string literal" do
      literal = "'" <> String.duplicate("a{{b}}''; ", 500_000) <> "'"
      filler = String.duplicate("SELECT 1 -- c\n", 357_143)
      text = "SELECT " <> literal <> " AS x, {{y}} " <> filler

      tokens = Tokenizer.tokenize(text, pg())
      assert {:string, ^literal} = Enum.at(tokens, 1)
      assert Tokenizer.to_string(tokens) == text
    end

    test "a million nested [[ does not grow the stack" do
      text = String.duplicate("[[", 1_000_000)
      assert Tokenizer.tokenize(text, pg()) == [{:code, text}]
    end

    test "deeply nested blocks" do
      text = String.duplicate("[[", 50_000) <> "x" <> String.duplicate("]]", 50_000)
      assert text |> Tokenizer.tokenize(pg()) |> Tokenizer.to_string() == text
    end
  end
end
