defmodule Lotus.Source.Adapters.Ecto.SQL.SanitizerTest do
  use ExUnit.Case, async: true

  alias Lotus.Source.Adapters.Ecto.SQL.Sanitizer

  describe "strip_trailing_semicolon/1" do
    test "strips trailing semicolon" do
      assert Sanitizer.strip_trailing_semicolon("SELECT 1;") == "SELECT 1"
    end

    test "strips trailing semicolon with whitespace" do
      assert Sanitizer.strip_trailing_semicolon("SELECT 1 ;  ") == "SELECT 1"
    end

    test "returns unchanged SQL without trailing semicolon" do
      assert Sanitizer.strip_trailing_semicolon("SELECT 1") == "SELECT 1"
    end

    test "handles CTE query with trailing semicolon" do
      sql = "WITH cte AS (SELECT 1) SELECT * FROM cte;"
      assert Sanitizer.strip_trailing_semicolon(sql) == "WITH cte AS (SELECT 1) SELECT * FROM cte"
    end
  end
end
