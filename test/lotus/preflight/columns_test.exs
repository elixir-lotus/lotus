defmodule Lotus.Preflight.ColumnsTest do
  use ExUnit.Case, async: true

  alias Lotus.Preflight.Columns
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Visibility

  @matcher Visibility.compile(%{column: [{"users", "ssn", [action: :mask, mask: :sha256]}]})
  @postgres Profile.for_language("sql:postgres")
  @relations [{"public", "users"}]

  defp check(sql, profile \\ @postgres, relations \\ @relations),
    do: Columns.check(sql, profile, @matcher, relations)

  describe "a protected column selected as is" do
    for sql <- [
          "SELECT ssn FROM users",
          "SELECT ssn, name FROM users WHERE id = 1 ORDER BY name LIMIT 5",
          "SELECT u.ssn, u.name FROM users u WHERE u.id = $1",
          "SELECT public.users.ssn FROM public.users",
          "SELECT ssn AS ssn FROM users",
          "SELECT DISTINCT ssn FROM users",
          "SELECT * FROM users",
          "SELECT u.* FROM users u",
          "SELECT count(*), name FROM users GROUP BY name",
          "SELECT name AS ssn FROM users",
          "SELECT left(name, 2) FROM users",
          "SELECT x.ssn FROM (SELECT * FROM users) x",
          "SELECT * FROM (SELECT ssn FROM users) AS lotus_sub LIMIT $1 OFFSET $2",
          ~s(WITH _base AS (SELECT ssn, name FROM users\) SELECT * FROM _base WHERE "name" = $2),
          "SELECT name FROM users WHERE note = 'ssn AS s' -- upper(ssn)"
        ] do
      test "passes: #{sql}" do
        assert :ok = check(unquote(sql))
      end
    end
  end

  describe "a protected column renamed, transformed or read elsewhere" do
    for sql <- [
          "SELECT ssn AS s FROM users",
          "SELECT ssn s FROM users",
          ~s(SELECT ssn AS "x" FROM users),
          ~s(SELECT "ssn" AS x FROM users),
          "SELECT SSN AS x FROM users",
          "SELECT upper(ssn) FROM users",
          "SELECT ssn || '' AS x FROM users",
          "SELECT ssn::int FROM users",
          "SELECT CAST(ssn AS int) FROM users",
          "SELECT name FROM users WHERE ssn = '123'",
          "SELECT name FROM users ORDER BY ssn",
          "SELECT ssn, count(*) FROM users GROUP BY ssn",
          ~s(WITH _sorted AS (SELECT ssn FROM users\) SELECT * FROM _sorted ORDER BY "ssn" DESC),
          "SELECT name FROM users UNION SELECT ssn FROM users",
          "SELECT (SELECT ssn FROM users LIMIT 1) AS x",
          "SELECT name FROM users WHERE EXISTS (SELECT ssn FROM users)",
          "WITH c AS (SELECT ssn AS s FROM users) SELECT s FROM c",
          "SELECT * FROM ((SELECT ssn FROM users)) x"
        ] do
      test "refused: #{sql}" do
        assert {:error, "Query uses protected column " <> _} = check(unquote(sql))
      end
    end
  end

  describe "a statement over a table with protected columns" do
    for sql <- [
          "SELECT u FROM users u",
          "SELECT to_json(u) FROM users u",
          "SELECT row_to_json(users) FROM users",
          "SELECT to_json(u.*) FROM users u",
          "WITH c AS (SELECT * FROM users) SELECT to_json(c) FROM c"
        ] do
      test "refuses a whole-row reference: #{sql}" do
        assert {:error, "Query reads whole rows of " <> _} = check(unquote(sql))
      end
    end

    for sql <- [
          "SELECT * FROM (SELECT * FROM users) t(a, b, c)",
          "SELECT * FROM users AS u(a, b)",
          "WITH c(x) AS (SELECT ssn FROM users) SELECT x FROM c"
        ] do
      test "refuses a column alias list: #{sql}" do
        assert {:error, "Query renames the columns " <> _} = check(unquote(sql))
      end
    end

    test "refuses * across a set operation" do
      assert {:error, "Query combines * with UNION" <> _} =
               check("SELECT name, name FROM users UNION SELECT * FROM users")
    end

    test "fails closed on the alias of a function in FROM" do
      assert {:error, "Query reads whole rows of g" <> _} =
               check("SELECT u.name, g FROM users u, get_users() g")

      assert {:error, "Query renames the columns " <> _} =
               check("SELECT g.a FROM users u, get_users() AS g(a, b)")

      assert :ok = check("SELECT u.name, g.n FROM users u, generate_series(1, 3) AS g")
    end

    for sql <- [
          "SELECT u.name, g FROM users u, generate_series(1, 3) g",
          "SELECT week, count(u.id) FROM generate_series(1, 3) AS week JOIN users u ON u.id < week GROUP BY week",
          "SELECT w.week FROM users u, generate_series(1, 3) AS w(week)",
          "SELECT i FROM users u, generate_subscripts(ARRAY[1, 2], 1) AS i"
        ] do
      test "passes the alias of a function whose rows are values: #{sql}" do
        assert :ok = check(unquote(sql))
      end
    end

    test "still checks a scalar function's arguments" do
      assert {:error, "Query uses protected column ssn" <> _} =
               check("SELECT g FROM users u, generate_series(1, length(u.ssn)) g")
    end

    for sql <- [
          "SELECT name, count(*) AS users FROM users GROUP BY name ORDER BY users DESC",
          "SELECT name, count(*) AS users FROM users GROUP BY 1 ORDER BY users",
          "SELECT name AS u FROM users u ORDER BY u NULLS LAST, name",
          "SELECT count(*) AS users FROM users ORDER BY name, users DESC LIMIT 5",
          "SELECT name AS users FROM users UNION SELECT name FROM users ORDER BY users"
        ] do
      test "passes a sort by an output column named as a table: #{sql}" do
        assert :ok = check(unquote(sql))
      end
    end

    for sql <- [
          "SELECT name FROM users ORDER BY users",
          "SELECT count(*) AS users FROM users ORDER BY users || ''",
          "SELECT count(*) AS users FROM users GROUP BY users",
          "SELECT (SELECT count(*) AS users FROM users) AS n FROM users ORDER BY users",
          "SELECT name, row_number() OVER (ORDER BY users) AS users FROM users"
        ] do
      test "refuses a sort by a table's whole row: #{sql}" do
        assert {:error, "Query reads whole rows of users" <> _} = check(unquote(sql))
      end
    end
  end

  describe "a sort or grouping by position" do
    for sql <- [
          "SELECT ssn FROM users ORDER BY 1",
          "SELECT name, ssn FROM users ORDER BY 2 DESC",
          "SELECT name, ssn FROM users ORDER BY 1, 2",
          "SELECT name, ssn FROM users ORDER BY 2 NULLS FIRST LIMIT 5",
          "SELECT name, ssn FROM users ORDER BY 2 COLLATE \"C\"",
          "SELECT ssn FROM users GROUP BY 1",
          "SELECT name, ssn FROM users GROUP BY 1, 2 WITH ROLLUP",
          "SELECT u.ssn, u.name FROM users u ORDER BY 1",
          "SELECT public.users.ssn FROM public.users ORDER BY 1",
          "SELECT ssn AS ssn, name FROM users ORDER BY 1",
          "SELECT DISTINCT name, ssn FROM users ORDER BY 2",
          "SELECT name, ssn FROM users ORDER BY (2)",
          "SELECT name, ssn FROM users ORDER BY ((2))",
          "SELECT name, ssn FROM users GROUP BY ROLLUP (1, 2)",
          "SELECT name, ssn FROM users GROUP BY CUBE (2)",
          "SELECT name, ssn FROM users GROUP BY GROUPING SETS ((2), ())",
          "SELECT DISTINCT ON (1) ssn, name FROM users",
          "SELECT * FROM (SELECT ssn FROM users ORDER BY 1) t",
          "WITH c AS (SELECT name, ssn FROM users ORDER BY 2) SELECT * FROM c",
          "SELECT t.name, t.ssn FROM (SELECT name, ssn FROM users) t ORDER BY 2"
        ] do
      test "refuses a position that is a protected column: #{sql}" do
        assert {:error, "Query sorts or groups by position " <> _} = check(unquote(sql))
      end
    end

    for sql <- [
          "SELECT * FROM users ORDER BY 3",
          "SELECT * FROM users ORDER BY 1",
          "SELECT u.*, name FROM users u ORDER BY 2",
          "SELECT name, u.* FROM users u GROUP BY 2",
          "SELECT name FROM users ORDER BY 2",
          "SELECT name FROM users ORDER BY 0",
          "TABLE users ORDER BY 3",
          "TABLE users ORDER BY name, 2 DESC",
          "TABLE public.users ORDER BY (1)",
          "SELECT * FROM (TABLE users ORDER BY 1 LIMIT 5) t",
          "SELECT name FROM users WHERE id IN (SELECT id FROM users GROUP BY 2)"
        ] do
      test "refuses a position it can't match to a select item: #{sql}" do
        assert {:error, "Query sorts or groups by position " <> rest} = check(unquote(sql))
        assert rest =~ "can't match to a select item"
      end
    end

    for sql <- [
          "SELECT name, ssn FROM users ORDER BY 1",
          "SELECT name, ssn FROM users ORDER BY 1 DESC, name",
          "SELECT name, * FROM users ORDER BY 1",
          "SELECT name AS ssn FROM users ORDER BY 1",
          "SELECT name, count(*) FROM users GROUP BY 1 ORDER BY 2 DESC",
          "SELECT name FROM users UNION SELECT name FROM users ORDER BY 1",
          "SELECT name, ssn FROM users ORDER BY 2 + 0",
          "SELECT name, ssn FROM users ORDER BY 2::int",
          "SELECT name, ssn FROM users ORDER BY coalesce(name, 2)",
          "SELECT name, ssn FROM users LIMIT 2 OFFSET 2",
          "SELECT name, ssn FROM users WHERE id IN (1, 2)",
          "SELECT name, ssn, row_number() OVER (ORDER BY 2) AS n FROM users",
          "SELECT name, ssn, rank() OVER (PARTITION BY 1, 2 ORDER BY name) AS n FROM users",
          "SELECT name, string_agg(name, ',' ORDER BY 2) FROM users GROUP BY name",
          ~s(WITH _sorted AS (SELECT name, ssn FROM users ORDER BY 1\) SELECT * FROM _sorted ORDER BY "name" DESC),
          "TABLE users",
          "TABLE users ORDER BY name LIMIT 5 OFFSET 2",
          "TABLE users ORDER BY name LIMIT 1, 2"
        ] do
      test "passes a position that is no protected column: #{sql}" do
        assert :ok = check(unquote(sql))
      end
    end
  end

  test "a Unicode-escaped identifier can't be compared, so it is refused" do
    assert {:error, "Query uses a Unicode-escaped identifier" <> _} =
             check(~S(SELECT U&"\0073sn" AS x FROM users))
  end

  test "MySQL backticks quote an identifier" do
    mysql = Profile.for_language("sql:mysql")

    assert :ok = check("SELECT `ssn` FROM users", mysql)
    assert {:error, _} = check("SELECT `ssn` AS x FROM users", mysql)
  end

  test "a column-only rule applies whatever the relations" do
    matcher = Visibility.compile(%{column: [{"pin", :omit}]})

    assert :ok = Columns.check("SELECT '1234' AS pin", @postgres, matcher, [])
    assert {:error, _} = Columns.check("SELECT upper(pin) FROM cards", @postgres, matcher, [])
  end

  test "without a protected column, anything passes" do
    assert :ok =
             check("SELECT ssn AS s, to_json(u) FROM users u", @postgres, [{"public", "posts"}])

    allow = Visibility.compile(%{column: [{"users", "ssn", :allow}]})
    assert :ok = Columns.check("SELECT upper(ssn) FROM users", @postgres, allow, @relations)
  end
end
