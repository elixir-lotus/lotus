defmodule Lotus.SQL.TransformerTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.SQL.Transformer

  defp pg, do: Profile.for_language("sql:postgres")
  defp mysql, do: Profile.for_language("sql:mysql")

  describe "strip_quoted_variables/2" do
    test "unwraps a quoted placeholder" do
      assert Transformer.strip_quoted_variables("WHERE email = '{{email}}'", pg()) ==
               "WHERE email = {{email}}"
    end

    test "leaves a literal with other content alone" do
      sql = "WHERE email = '{{email}}@x'"
      assert Transformer.strip_quoted_variables(sql, pg()) == sql
    end

    test "leaves a quoted placeholder inside a comment alone" do
      sql = "-- use '{{x}}' here\nSELECT 1"
      assert Transformer.strip_quoted_variables(sql, pg()) == sql
    end

    test "pairs quotes correctly after a literal with an escaped apostrophe" do
      sql = "WHERE name = 'O''Brien' AND email = '{{email}}'"

      assert Transformer.strip_quoted_variables(sql, pg()) ==
               "WHERE name = 'O''Brien' AND email = {{email}}"
    end

    test "unwraps a double-quoted placeholder on mysql" do
      assert Transformer.strip_quoted_variables(~S|WHERE email = "{{email}}"|, mysql()) ==
               "WHERE email = {{email}}"
    end

    test "leaves a double-quoted identifier alone on postgres" do
      sql = ~S|SELECT "{{col}}" FROM t|
      assert Transformer.strip_quoted_variables(sql, pg()) == sql
    end
  end

  describe "transform_wildcards/3" do
    test "rewrites a wildcard literal with the pipe operator" do
      assert Transformer.transform_wildcards("LIKE '%{{q}}%'", :pipe, pg()) ==
               "LIKE '%' || {{q}} || '%'"
    end

    test "rewrites with CONCAT" do
      assert Transformer.transform_wildcards("LIKE '%{{q}}'", :concat_fn, mysql()) ==
               "LIKE CONCAT('%', {{q}})"
    end

    test "leaves a wildcard literal inside a comment alone" do
      sql = "-- LIKE '%{{q}}%'\nSELECT 1"
      assert Transformer.transform_wildcards(sql, :pipe, pg()) == sql
    end

    test "pairs quotes correctly after a literal with an escaped apostrophe" do
      sql = "WHERE name = 'O''Brien' AND q LIKE '{{q}}%'"

      assert Transformer.transform_wildcards(sql, :pipe, pg()) ==
               "WHERE name = 'O''Brien' AND q LIKE {{q}} || '%'"
    end

    test "leaves a dollar-quoted body alone on postgres" do
      sql = "SELECT $$'%{{q}}%'$$"
      assert Transformer.transform_wildcards(sql, :pipe, pg()) == sql
    end
  end

  describe "transform_pg_intervals/2" do
    test "rewrites a bare placeholder" do
      assert Transformer.transform_pg_intervals("now() - INTERVAL {{d}}", pg()) ==
               "now() - ({{d}}::text)::interval"
    end

    test "rewrites a quoted placeholder" do
      assert Transformer.transform_pg_intervals("now() - INTERVAL '{{d}}'", pg()) ==
               "now() - CAST({{d}} AS interval)"
    end

    test "rewrites a placeholder with a unit" do
      assert Transformer.transform_pg_intervals("now() - INTERVAL '{{n}} days'", pg()) ==
               "now() - make_interval(days => ({{n}})::integer)"
    end

    test "rewrites a lowercase keyword" do
      assert Transformer.transform_pg_intervals("now() - interval '{{n}} day'", pg()) ==
               "now() - make_interval(days => ({{n}})::integer)"
    end

    test "rewrites a number with a placeholder unit" do
      assert Transformer.transform_pg_intervals("INTERVAL '7 {{unit}}'", pg()) ==
               "(( '7 ' || {{unit}} )::interval)"
    end

    test "rewrites two placeholders" do
      assert Transformer.transform_pg_intervals("INTERVAL '{{n}} {{unit}}'", pg()) ==
               "((CAST({{n}} AS text) || ' ' || {{unit}})::interval)"
    end

    test "leaves a bare placeholder followed by a unit keyword alone" do
      sql = "INTERVAL {{n}} DAY"
      assert Transformer.transform_pg_intervals(sql, pg()) == sql
    end

    test "leaves an interval inside a comment alone" do
      sql = "-- INTERVAL '{{n}} days'\nSELECT {{n}}"
      assert Transformer.transform_pg_intervals(sql, pg()) == sql
    end

    test "leaves a plain interval literal alone" do
      sql = "now() - INTERVAL '7 days'"
      assert Transformer.transform_pg_intervals(sql, pg()) == sql
    end
  end
end
