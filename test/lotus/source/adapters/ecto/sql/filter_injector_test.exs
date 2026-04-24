defmodule Lotus.Source.Adapters.Ecto.SQL.FilterInjectorTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Filter
  alias Lotus.Source.Adapters.Ecto.SQL.FilterInjector

  defp double_quote(id), do: ~s("#{id}")
  defp backtick_quote(id), do: "`#{id}`"
  defp pg_placeholder(idx), do: "$#{idx}"
  defp mysql_placeholder(_idx), do: "?"

  describe "apply/5" do
    test "returns original SQL and params when filters is empty" do
      sql = "SELECT * FROM users"

      assert FilterInjector.apply(sql, [25], [], &double_quote/1, &pg_placeholder/1) ==
               {sql, [25]}
    end

    test "wraps SQL in CTE with parameterized eq filter" do
      sql = "SELECT * FROM users"
      filters = [Filter.new("region", :eq, "US")]

      {result, params} =
        FilterInjector.apply(sql, [], filters, &double_quote/1, &pg_placeholder/1)

      assert result ==
               ~s[WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE "region" = $1]

      assert params == ["US"]
    end

    test "handles multiple filters with AND and correct parameter indices" do
      sql = "SELECT * FROM orders"

      filters = [
        Filter.new("region", :eq, "US"),
        Filter.new("status", :neq, "cancelled")
      ]

      {result, params} =
        FilterInjector.apply(sql, [], filters, &double_quote/1, &pg_placeholder/1)

      assert result ==
               ~s[WITH _base AS (SELECT * FROM orders) SELECT * FROM _base WHERE "region" = $1 AND "status" != $2]

      assert params == ["US", "cancelled"]
    end

    test "continues parameter indexing from existing params" do
      sql = "SELECT * FROM users WHERE age > $1"
      existing_params = [25]
      filters = [Filter.new("region", :eq, "US")]

      {result, params} =
        FilterInjector.apply(sql, existing_params, filters, &double_quote/1, &pg_placeholder/1)

      assert result ==
               ~s[WITH _base AS (SELECT * FROM users WHERE age > $1) SELECT * FROM _base WHERE "region" = $2]

      assert params == [25, "US"]
    end

    test "handles numeric values as parameters" do
      filters = [Filter.new("price", :gt, 100)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM products",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("price" > $1)
      assert params == [100]
    end

    test "handles float values as parameters" do
      filters = [Filter.new("rating", :gte, 4.5)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM reviews",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("rating" >= $1)
      assert params == [4.5]
    end

    test "handles IS NULL operator without parameters" do
      filters = [Filter.new("deleted_at", :is_null)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("deleted_at" IS NULL)
      assert params == []
    end

    test "handles IS NOT NULL operator without parameters" do
      filters = [Filter.new("email", :is_not_null)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("email" IS NOT NULL)
      assert params == []
    end

    test "handles LIKE operator with parameterized value" do
      filters = [Filter.new("name", :like, "%John%")]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("name" LIKE $1)
      assert params == ["%John%"]
    end

    test "string values with special characters are safely parameterized" do
      filters = [Filter.new("name", :eq, "O'Brien; DROP TABLE users; --")]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("name" = $1)
      assert params == ["O'Brien; DROP TABLE users; --"]
      refute result =~ "O'Brien"
    end

    test "handles boolean values as parameters" do
      filters = [Filter.new("active", :eq, true)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("active" = $1)
      assert params == [true]
    end

    test "works with MySQL-style placeholders" do
      filters = [
        Filter.new("region", :eq, "US"),
        Filter.new("status", :eq, "active")
      ]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &backtick_quote/1,
          &mysql_placeholder/1
        )

      assert result ==
               "WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE `region` = ? AND `status` = ?"

      assert params == ["US", "active"]
    end

    test "handles all comparison operators" do
      ops = [eq: "=", neq: "!=", gt: ">", lt: "<", gte: ">=", lte: "<=", like: "LIKE"]

      for {op, sql_op} <- ops do
        filters = [Filter.new("col", op, "val")]

        {result, params} =
          FilterInjector.apply("SELECT 1", [], filters, &double_quote/1, &pg_placeholder/1)

        assert result =~ ~s("col" #{sql_op} $1), "Failed for op: #{op}"
        assert params == ["val"]
      end
    end

    test "strips trailing semicolon before wrapping in CTE" do
      sql = "SELECT * FROM users;"
      filters = [Filter.new("region", :eq, "US")]

      {result, _params} =
        FilterInjector.apply(sql, [], filters, &double_quote/1, &pg_placeholder/1)

      assert result ==
               ~s[WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE "region" = $1]
    end

    test "strips trailing semicolon with surrounding whitespace" do
      sql = "SELECT * FROM users ;  "
      filters = [Filter.new("region", :eq, "US")]

      {result, _params} =
        FilterInjector.apply(sql, [], filters, &double_quote/1, &pg_placeholder/1)

      assert result ==
               ~s[WITH _base AS (SELECT * FROM users) SELECT * FROM _base WHERE "region" = $1]
    end

    test "handles CTE query with trailing semicolon" do
      sql = """
      WITH cte AS (SELECT id, name FROM users)
      SELECT * FROM cte;
      """

      filters = [Filter.new("name", :eq, "test")]

      {result, params} =
        FilterInjector.apply(sql, [], filters, &double_quote/1, &pg_placeholder/1)

      assert result =~ "WITH _base AS ("
      refute result =~ ";"
      assert result =~ ~s(SELECT * FROM _base WHERE "name" = $1)
      assert params == ["test"]
    end

    test "wraps complex queries safely" do
      sql =
        "SELECT a.*, b.name FROM a JOIN b ON a.id = b.a_id WHERE a.active = true UNION SELECT c.*, d.name FROM c JOIN d ON c.id = d.c_id"

      filters = [Filter.new("name", :eq, "test")]

      {result, params} =
        FilterInjector.apply(sql, [], filters, &double_quote/1, &pg_placeholder/1)

      assert result =~ "WITH _base AS (#{sql})"
      assert result =~ ~s(SELECT * FROM _base WHERE "name" = $1)
      assert params == ["test"]
    end

    test "handles eq with nil value as IS NULL" do
      filters = [Filter.new("deleted_at", :eq, nil)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("deleted_at" IS NULL)
      assert params == []
    end

    test "handles neq with nil value as IS NOT NULL" do
      filters = [Filter.new("deleted_at", :neq, nil)]

      {result, params} =
        FilterInjector.apply(
          "SELECT * FROM users",
          [],
          filters,
          &double_quote/1,
          &pg_placeholder/1
        )

      assert result =~ ~s("deleted_at" IS NOT NULL)
      assert params == []
    end
  end

  describe "column validation" do
    test "rejects column names with SQL injection attempts" do
      filters = [Filter.new("col; DROP TABLE users", :eq, "val")]

      assert_raise ArgumentError, ~r/Invalid filter column/, fn ->
        FilterInjector.apply("SELECT 1", [], filters, &double_quote/1, &pg_placeholder/1)
      end
    end

    test "rejects column names with special characters" do
      for bad_col <- ["col name", "col'name", "col\"name", "col;name", "col--name"] do
        filters = [Filter.new(bad_col, :eq, "val")]

        assert_raise ArgumentError, ~r/Invalid filter column/, fn ->
          FilterInjector.apply("SELECT 1", [], filters, &double_quote/1, &pg_placeholder/1)
        end
      end
    end

    test "accepts valid column names" do
      for good_col <- ["name", "user_name", "_id", "Column1", "a"] do
        filters = [Filter.new(good_col, :eq, "val")]

        {_result, _params} =
          FilterInjector.apply("SELECT 1", [], filters, &double_quote/1, &pg_placeholder/1)
      end
    end
  end
end
