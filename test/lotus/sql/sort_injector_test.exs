defmodule Lotus.SQL.SortInjectorTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Sort
  alias Lotus.SQL.SortInjector

  defp double_quote(id), do: ~s("#{id}")
  defp backtick_quote(id), do: "`#{id}`"

  describe "apply/3" do
    test "returns original SQL when sorts is empty" do
      sql = "SELECT * FROM users"
      assert SortInjector.apply(sql, [], &double_quote/1) == sql
    end

    test "wraps SQL in CTE with single asc sort" do
      sql = "SELECT * FROM users"
      sorts = [Sort.new("name", :asc)]

      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (SELECT * FROM users) SELECT * FROM _sorted ORDER BY "name" ASC]
    end

    test "wraps SQL in CTE with single desc sort" do
      sql = "SELECT * FROM users"
      sorts = [Sort.new("created_at", :desc)]

      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (SELECT * FROM users) SELECT * FROM _sorted ORDER BY "created_at" DESC]
    end

    test "handles multiple sorts" do
      sql = "SELECT * FROM orders"

      sorts = [
        Sort.new("status", :asc),
        Sort.new("created_at", :desc)
      ]

      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (SELECT * FROM orders) SELECT * FROM _sorted ORDER BY "status" ASC, "created_at" DESC]
    end

    test "works with backtick quoting (MySQL style)" do
      sorts = [Sort.new("name", :asc)]
      result = SortInjector.apply("SELECT * FROM users", sorts, &backtick_quote/1)

      assert result ==
               "WITH _sorted AS (SELECT * FROM users) SELECT * FROM _sorted ORDER BY `name` ASC"
    end

    test "strips trailing semicolon before wrapping in CTE" do
      sql = "SELECT * FROM users;"
      sorts = [Sort.new("name", :asc)]

      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (SELECT * FROM users) SELECT * FROM _sorted ORDER BY "name" ASC]
    end

    test "strips trailing semicolon with surrounding whitespace" do
      sql = "SELECT * FROM users ;  "
      sorts = [Sort.new("name", :asc)]

      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (SELECT * FROM users) SELECT * FROM _sorted ORDER BY "name" ASC]
    end

    test "safely wraps queries that already have ORDER BY" do
      sql = "SELECT * FROM users ORDER BY id"
      sorts = [Sort.new("name", :desc)]

      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (SELECT * FROM users ORDER BY id) SELECT * FROM _sorted ORDER BY "name" DESC]
    end

    test "works after CTE-wrapped filtered query" do
      sql =
        ~s[WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE "region" = $1]

      sorts = [Sort.new("name", :asc)]
      result = SortInjector.apply(sql, sorts, &double_quote/1)

      assert result ==
               ~s[WITH _sorted AS (WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE "region" = $1) SELECT * FROM _sorted ORDER BY "name" ASC]
    end
  end

  describe "column validation" do
    test "rejects column names with SQL injection attempts" do
      sorts = [Sort.new("name; DROP TABLE users", :asc)]

      assert_raise ArgumentError, ~r/Invalid sort column/, fn ->
        SortInjector.apply("SELECT 1", sorts, &double_quote/1)
      end
    end

    test "rejects column names with special characters" do
      for bad_col <- ["col name", "col'name", "col\"name", "col;name", "col--name"] do
        sorts = [Sort.new(bad_col, :asc)]

        assert_raise ArgumentError, ~r/Invalid sort column/, fn ->
          SortInjector.apply("SELECT 1", sorts, &double_quote/1)
        end
      end
    end

    test "accepts valid column names" do
      for good_col <- ["name", "user_name", "_id", "Column1", "a"] do
        sorts = [Sort.new(good_col, :asc)]
        result = SortInjector.apply("SELECT 1", sorts, &double_quote/1)
        assert result =~ "ORDER BY"
      end
    end
  end
end
