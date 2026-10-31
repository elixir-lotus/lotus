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

    for sql <- [
          "SELECT name FROM users NATURAL JOIN (SELECT 1 AS ssn) p",
          "SELECT name FROM users NATURAL LEFT JOIN orders",
          "SELECT name FROM users natural inner join orders o",
          "SELECT name FROM orders o NATURAL RIGHT OUTER JOIN users",
          "SELECT name FROM users NATURAL FULL JOIN orders",
          "SELECT * FROM (SELECT name FROM users NATURAL JOIN orders) t"
        ] do
      test "refuses a NATURAL join: #{sql}" do
        assert {:error, "Query joins with NATURAL " <> _} = check(unquote(sql))
      end
    end

    test "passes a NATURAL join when no touched relation has protected columns" do
      assert :ok =
               check("SELECT id FROM orders NATURAL JOIN payments", @postgres, [
                 {"public", "orders"},
                 {"public", "payments"}
               ])
    end

    test "refuses * across a set operation" do
      assert {:error, "Query combines * with UNION" <> _} =
               check("SELECT name, name FROM users UNION SELECT * FROM users")
    end

    # `TABLE users` is `SELECT * FROM users`: after a first branch it would
    # return ssn under that branch's names.
    for sql <- [
          "SELECT name, email FROM orders UNION ALL TABLE users",
          "SELECT id, name FROM users EXCEPT TABLE public.users",
          "TABLE users INTERSECT SELECT id, name FROM users",
          "(TABLE users) UNION (SELECT id, name FROM users)"
        ] do
      test "refuses TABLE across a set operation: #{sql}" do
        assert {:error, "Query combines * with UNION" <> _} = check(unquote(sql))
      end
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

  describe "a name qualified by a relation without the protected column" do
    @joined [{"public", "users"}, {"public", "orders"}]

    for sql <- [
          "SELECT o.ssn AS order_ssn FROM orders o JOIN users u ON u.id = o.user_id",
          "SELECT upper(o.ssn) FROM orders o JOIN users u ON u.id = o.user_id WHERE o.ssn = '1' ORDER BY o.ssn",
          "SELECT orders.ssn AS s FROM orders JOIN users ON users.id = orders.user_id",
          "SELECT public.orders.ssn AS s FROM public.orders JOIN users ON true",
          "SELECT public.orders.ssn AS s FROM orders JOIN users ON true",
          "SELECT o.ssn AS s FROM public.orders AS o JOIN users u ON true",
          "SELECT o.ssn AS s FROM orders o JOIN users o2 ON true",
          "SELECT O.ssn AS s FROM Orders O JOIN users u ON true",
          ~s(SELECT o."ssn" AS s FROM orders o JOIN users u ON true),
          ~s(SELECT "o".ssn AS s FROM "orders" "o" JOIN users u ON true),
          "SELECT o.SSN AS s FROM orders o JOIN users u ON true",
          "SELECT name FROM users WHERE id IN (SELECT o.user_id FROM orders o WHERE o.ssn = '1')",
          "SELECT o.ssn, u.name FROM orders o JOIN users u ON true ORDER BY 1",
          "SELECT o.*, u.name FROM orders o JOIN users u ON true ORDER BY 3"
        ] do
      test "passes: #{sql}" do
        assert :ok = check(unquote(sql), @postgres, @joined)
      end
    end

    for sql <- [
          # unqualified, or qualified by the protected relation
          "SELECT ssn AS s FROM orders o JOIN users u ON u.id = o.user_id",
          "SELECT u.ssn AS s FROM orders o JOIN users u ON u.id = o.user_id",
          "SELECT o2.ssn AS s FROM orders o JOIN users o2 ON true",
          "SELECT public.users.ssn AS s FROM public.users JOIN orders ON true",
          # an alias named like another table
          "SELECT o.ssn AS s FROM users o",
          "SELECT orders.ssn AS s FROM users orders",
          "SELECT orders.ssn AS s FROM users AS orders JOIN orders o ON true",
          "SELECT orders.ssn AS s FROM orders o JOIN users u ON true",
          # a CTE or derived table that can carry the column
          "WITH orders AS (SELECT ssn FROM users) SELECT o.ssn AS s FROM orders o",
          "WITH orders AS (SELECT ssn FROM users) SELECT orders.ssn AS s FROM orders",
          ~s(WITH "Orders" AS (SELECT ssn FROM users\) SELECT o.ssn AS s FROM orders o),
          "SELECT o.ssn AS s FROM (SELECT * FROM users) o",
          "SELECT o.ssn AS s FROM orders o, LATERAL (SELECT ssn FROM users) o",
          # an alias bound twice, or standing elsewhere too
          ~s(SELECT "O".ssn AS s FROM orders "O" JOIN users o ON true),
          "SELECT (SELECT o.ssn FROM (users o JOIN orders x ON true)) AS s FROM orders o",
          "SELECT o.ssn AS s FROM orders o JOIN users u ON true WHERE o IS NOT NULL",
          "SELECT o.ssn AS s, u.name AS o FROM orders o JOIN users u ON true",
          # a schema or a table preflight didn't find
          "SELECT sales.orders.ssn AS s FROM orders JOIN users ON true",
          "SELECT p.ssn AS s FROM payments p JOIN users u ON true",
          "SELECT x.public.orders.ssn AS s FROM orders JOIN users ON true",
          "SELECT o.ssn AS s FROM db.public.orders o JOIN users ON true"
        ] do
      test "refuses: #{sql}" do
        assert {:error, "Query uses protected column ssn" <> _} =
                 check(unquote(sql), @postgres, @joined)
      end
    end

    for sql <- [
          "SELECT o.*, u.ssn FROM orders o JOIN users u ON true ORDER BY 3",
          "SELECT u.*, o.id FROM orders o JOIN users u ON true ORDER BY 3",
          "SELECT x.* FROM (SELECT * FROM orders) x JOIN users u ON true ORDER BY 1"
        ] do
      test "refuses a position after a t.* it can't size: #{sql}" do
        assert {:error, "Query sorts or groups by position " <> _} =
                 check(unquote(sql), @postgres, @joined)
      end
    end

    test "a relation's own policy decides, and a column-only rule applies to every relation" do
      both =
        Visibility.compile(%{
          column: [{"users", "ssn", :omit}, {"orders", "ssn", [action: :mask, mask: :sha256]}]
        })

      sql = "SELECT o.ssn AS s FROM orders o JOIN users u ON u.id = o.user_id"
      assert {:error, _} = Columns.check(sql, @postgres, both, @joined)

      anywhere = Visibility.compile(%{column: [{"ssn", :omit}]})
      assert {:error, _} = Columns.check(sql, @postgres, anywhere, @joined)

      schema = Visibility.compile(%{column: [{"public", "users", "ssn", :omit}]})
      assert :ok = Columns.check(sql, @postgres, schema, @joined)

      assert :ok =
               Columns.check(sql, @postgres, schema, [{"public", "users"}, {"sales", "orders"}])

      assert {:error, _} =
               Columns.check(sql, @postgres, schema, [
                 {"public", "users"},
                 {"public", "orders"},
                 {"sales", "orders"}
               ])
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

  test "SQLite brackets quote an identifier, with no escapes" do
    sqlite = Profile.for_language("sql:sqlite")

    assert :ok = check("SELECT [ssn], [my]]col] FROM users", sqlite)

    assert {:error, "Query uses protected column ssn" <> _} =
             check("SELECT [ssn] AS x FROM users", sqlite)
  end

  test "what a MySQL executable comment holds is checked as the code it is" do
    mysql = Profile.for_language("sql:mysql")

    assert {:error, "Query uses protected column ssn" <> _} =
             check("SELECT name /*! , ssn AS x */ FROM users", mysql)

    assert {:error, _} = check("SELECT name FROM users /*!50000 ORDER BY ssn */", mysql)
    assert :ok = check("SELECT name /* , ssn AS x */ FROM users", mysql)
  end

  test "words are taken as the databases take unquoted identifiers" do
    assert :ok = check("SELECT ssné AS x, ssn$1 AS y, _ssn AS z FROM users")
    assert {:error, _} = check("SELECT 1ssn AS x FROM users")
    assert {:error, "Query uses protected column SSN" <> _} = check("SELECT SSN AS x FROM users")
  end

  test "a column pattern protects every name it matches" do
    for rule <- [
          {"users", ~r/^ss/, :omit},
          {~r/^SS/i, :omit},
          {"public", "users", ~r/sn$/, :omit}
        ] do
      matcher = Visibility.compile(%{column: [rule]})
      check = &Columns.check(&1, @postgres, matcher, @relations)

      assert {:error, _} = check.("SELECT upper(ssn) FROM users")
      assert :ok = check.("SELECT upper(name) AS x FROM users")
    end

    star = Visibility.compile(%{column: [{"users", "*", :omit}]})

    assert {:error, _} =
             Columns.check("SELECT upper(name) FROM users", @postgres, star, @relations)
  end

  test "a column-only rule applies whatever the relations" do
    matcher = Visibility.compile(%{column: [{"pin", :omit}]})

    assert :ok = Columns.check("SELECT '1234' AS pin", @postgres, matcher, [])
    assert {:error, _} = Columns.check("SELECT upper(pin) FROM cards", @postgres, matcher, [])
  end

  describe "the relation a result column comes from" do
    @users {"public", "users"}
    @orders {"public", "orders"}
    @both [@users, @orders]
    @per_table Visibility.compile(%{
                 column: [{"orders", "ssn", :allow}, {"users", "ssn", :mask}]
               })

    defp sources(sql, matcher \\ @per_table, relations \\ @both),
      do: Columns.result_sources(sql, @postgres, matcher, relations)

    test "is the relation a qualified column as is names" do
      join = "FROM users u JOIN orders o ON o.user_id = u.id"

      assert {:ok, [{:relation, @users}]} = sources("SELECT u.ssn #{join}")
      assert {:ok, [{:relation, @orders}]} = sources("SELECT o.ssn #{join}")

      assert {:ok, [{:relation, @orders}, {:relation, @users}]} =
               sources(~s|SELECT DISTINCT o.ssn, u.ssn AS "SSN" #{join}|)

      assert {:ok, [{:relation, @users}, :unresolved]} =
               sources(
                 "SELECT public.users.ssn, upper(o.ssn) FROM public.users JOIN orders o ON true"
               )
    end

    test "is unresolved for a column whose relation the statement doesn't tell" do
      assert {:ok, [:unresolved, :unresolved]} =
               sources("SELECT ssn, x.ssn FROM (SELECT ssn FROM users) x JOIN orders o ON true")

      assert {:ok, [:unresolved]} =
               sources("SELECT o.ssn FROM orders o JOIN users o ON true")

      assert {:ok, [{:relation, @orders}]} =
               sources("SELECT o.ssn, * FROM orders o JOIN users u ON true")

      assert {:ok, []} = sources("SELECT u.*, o.ssn FROM orders o JOIN users u ON true")
    end

    test "is unknown across a set operation" do
      assert {:ok, nil} = sources("SELECT u.name FROM users u UNION SELECT o.name FROM orders o")
    end

    test "is told without a protected column too, for a plug with rules of its own" do
      none = Visibility.compile(%{})
      join = "FROM users u JOIN orders o ON o.user_id = u.id"

      assert {:ok, [{:relation, @orders}]} =
               sources("SELECT o.ssn FROM orders o", @per_table, [@orders])

      assert {:ok, [{:relation, @users}, {:relation, @orders}, :unresolved, :unresolved]} =
               sources("SELECT u.ssn, o.ssn AS ssn, ssn, lower(u.name) #{join}", none)

      assert {:ok, nil} =
               sources("SELECT u.name FROM users u UNION SELECT o.name FROM orders o", none)
    end

    test "passes through a wrapper that selects * from one derived table or CTE" do
      none = Visibility.compile(%{})
      inner = "SELECT u.ssn, o.ssn AS ssn, lower(o.ssn) AS l FROM users u JOIN orders o ON true"
      expected = [{:relation, @users}, {:relation, @orders}, :unresolved]

      paged = "SELECT * FROM (#{inner}) AS lotus_sub LIMIT $1 OFFSET $2"
      filtered = ~s|WITH _base AS (#{inner}) SELECT * FROM _base WHERE "id" = $1|
      sorted = ~s|WITH _sorted AS (#{filtered}) SELECT * FROM _sorted ORDER BY "id" DESC|

      for sql <- [
            paged,
            filtered,
            sorted,
            "SELECT * FROM (#{sorted}) AS lotus_sub LIMIT $2 OFFSET $3;",
            "SELECT * FROM (#{inner}) AS limited_query LIMIT 10",
            "SELECT * FROM (#{inner}) t WHERE x IN (SELECT 1) ORDER BY x FETCH FIRST 5 ROWS ONLY",
            "SELECT * FROM (#{inner}) t"
          ],
          matcher <- [none, @per_table] do
        assert {:ok, ^expected} = sources(sql, matcher), sql
      end
    end

    test "keeps a wrapper's own sources when it may change the columns" do
      none = Visibility.compile(%{})
      inner = "SELECT u.ssn FROM users u JOIN orders o ON true"

      for sql <- [
            "SELECT *, 1 AS one FROM (#{inner}) t",
            "SELECT * FROM (#{inner}) t JOIN orders o2 ON true",
            "SELECT * FROM (#{inner}) t, orders o2",
            "SELECT * FROM (#{inner}) t UNION SELECT o.ssn FROM orders o",
            "SELECT * FROM (#{inner}) t ORDER BY 1 UNION ALL SELECT 'x'",
            "WITH a AS (#{inner}), b AS (SELECT 1) SELECT * FROM a",
            "WITH a AS (#{inner}) SELECT * FROM b",
            "WITH RECURSIVE a AS (#{inner}) SELECT * FROM a",
            "WITH a AS (#{inner}) SELECT * FROM a JOIN orders o2 ON true",
            "SELECT DISTINCT * FROM (#{inner}) t"
          ] do
        assert {:ok, sources} = sources(sql, none)
        assert sources in [nil, []], sql
      end

      assert {:ok, nil} = sources("SELECT * FROM (#{inner}) AS t(a)", none)
    end

    test "has the inner statement's sources, nothing more, through a wrapper" do
      none = Visibility.compile(%{})

      assert {:ok, nil} =
               sources(
                 "SELECT * FROM (SELECT u.ssn FROM users u UNION SELECT o.ssn FROM orders o) t",
                 none
               )

      assert {:ok, [{:relation, @users}]} =
               sources("SELECT * FROM (SELECT u.ssn, * FROM users u JOIN orders o ON true) t")

      assert {:ok, [:unresolved]} =
               sources(
                 "WITH c AS (SELECT ssn FROM users u JOIN orders o ON true) SELECT * FROM c"
               )
    end

    test "is unknown, and nothing refused, for a column alias list without a protected column" do
      none = Visibility.compile(%{})

      assert {:ok, nil} = sources("SELECT u.a FROM users AS u(a, b)", none, [@users])
      assert :ok = Columns.check("SELECT u.a FROM users AS u(a, b)", @postgres, none, [@users])
    end

    test "decides the check: a column is protected by its own relation's policy" do
      join = "FROM users u JOIN orders o ON o.user_id = u.id"

      assert {:ok, _} = sources("SELECT upper(o.ssn) #{join}")
      assert {:error, _} = sources("SELECT upper(u.ssn) #{join}")

      # Unqualified, the name may be either table's, so the strictest
      # policy applies whatever order the rules come in.
      assert {:error, _} = sources("SELECT upper(ssn) #{join}")

      reversed =
        Visibility.compile(%{column: [{"users", "ssn", :mask}, {"orders", "ssn", :allow}]})

      assert {:error, _} = sources("SELECT upper(ssn) #{join}", reversed)
      assert {:ok, _} = sources("SELECT upper(o.ssn) #{join}", reversed)
    end
  end

  test "a rule protects its column in any case" do
    upper = Visibility.compile(%{column: [{"users", "SSN", :omit}]})

    assert {:error, "Query uses protected column ssn" <> _} =
             Columns.check("SELECT upper(ssn) FROM users", @postgres, upper, @relations)

    assert :ok = Columns.check(~s|SELECT ssn AS "SSN" FROM users|, @postgres, upper, @relations)
  end

  test "without a protected column, anything passes" do
    assert :ok =
             check("SELECT ssn AS s, to_json(u) FROM users u", @postgres, [{"public", "posts"}])

    allow = Visibility.compile(%{column: [{"users", "ssn", :allow}]})
    assert :ok = Columns.check("SELECT upper(ssn) FROM users", @postgres, allow, @relations)
  end
end
