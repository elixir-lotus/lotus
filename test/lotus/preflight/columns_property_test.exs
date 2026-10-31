defmodule Lotus.Preflight.ColumnsPropertyTest do
  @moduledoc """
  Property and differential tests for `Lotus.Preflight.Columns`.

  The properties generate statements from a small SQL grammar over `users`,
  whose `ssn` column is protected, and `orders`, which has an `ssn` column
  too but no policy. The differential tests compare the check with
  `Lotus.Test.OldColumns`, a copy of it before sorts by position were
  checked, qualified names resolved and its lexer rewritten; they may only
  differ where a statement sorts or groups by position.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lotus.Preflight.Columns
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Test.OldColumns
  alias Lotus.Visibility

  @matcher Visibility.compile(%{column: [{"users", "ssn", [action: :mask, mask: :sha256]}]})
  @postgres Profile.for_language("sql:postgres")
  @mysql Profile.for_language("sql:mysql")
  @users [{"public", "users"}]
  @joined [{"public", "users"}, {"public", "orders"}]
  @runs String.to_integer(System.get_env("COLUMNS_PROPERTY_RUNS", "400"))

  defp run(sql, rels \\ @users), do: Columns.check(sql, @postgres, @matcher, rels)

  # ---------------------------------------------------------------------------
  # Grammar
  # ---------------------------------------------------------------------------

  @unprotected ~w(name email id)

  # `users` as FROM names it, and the alias its columns are qualified by.
  defp users_table do
    member_of([
      {"users", nil},
      {"users u", "u"},
      {"users AS u", "u"},
      {"public.users", nil},
      {"public.users AS u", "u"},
      {~s("users" u), "u"},
      {"USERS U", "U"}
    ])
  end

  # A column of `users` as a statement may write it.
  defp ref(column, nil) do
    member_of([
      column,
      ~s("#{column}"),
      String.upcase(column),
      "users.#{column}",
      "public.users.#{column}"
    ])
  end

  defp ref(column, alias), do: member_of([column, "#{alias}.#{column}", ~s(#{alias}."#{column}")])

  defp ssn(alias), do: ref("ssn", alias)
  defp unprotected(alias), do: bind(member_of(@unprotected), &ref(&1, alias))

  # A select item that keeps a protected column's name, or reads none:
  # `{text, position_safe?}`, position_safe? when sorting by its position
  # reveals no protected column.
  defp safe_item(alias) do
    one_of([
      map(ssn(alias), &{&1, false}),
      constant({"ssn AS ssn", false}),
      map(unprotected(alias), &{&1, true}),
      map(unprotected(alias), &{"upper(#{&1}) AS up", true}),
      map(unprotected(alias), &{"coalesce(#{&1}, '') AS c", true}),
      constant({"count(*) AS n", true}),
      constant({"1 AS one", true})
    ])
  end

  defp condition(alias) do
    bind(unprotected(alias), fn ref ->
      member_of([
        "#{ref} = 1",
        "#{ref} IS NOT NULL",
        "#{ref} IN (1, 2)",
        "#{ref} ILIKE 'a%'",
        "#{ref} > $1",
        "#{ref} BETWEEN 1 AND 3",
        "#{ref} = (SELECT max(id) FROM orders)"
      ])
    end)
  end

  defp sort(alias, items) do
    positions =
      for {{_text, true}, i} <- Enum.with_index(items, 1), do: Integer.to_string(i)

    by_name =
      bind(unprotected(alias), fn ref ->
        member_of([ref, "#{ref} DESC", "#{ref} ASC NULLS LAST"])
      end)

    if positions == [],
      do: by_name,
      else: one_of([by_name, member_of(positions), map(member_of(positions), &"#{&1} DESC")])
  end

  # A statement whose protected column reaches the result as is.
  defp safe_statement do
    gen all(
          {table, alias} <- users_table(),
          items <- list_of(safe_item(alias), min_length: 1, max_length: 4),
          distinct <- member_of(["", "DISTINCT "]),
          where <-
            one_of([constant(nil), list_of(condition(alias), min_length: 1, max_length: 2)]),
          group <- one_of([constant(nil), unprotected(alias)]),
          order <- one_of([constant(nil), sort(alias, items)]),
          limit <- member_of(["", " LIMIT 10", " LIMIT 10 OFFSET 5"]),
          wrap <- wrapper()
        ) do
      wrap.(
        "SELECT #{distinct}#{Enum.map_join(items, ", ", &elem(&1, 0))} FROM #{table}" <>
          if(where, do: " WHERE " <> Enum.join(where, " AND "), else: "") <>
          if(group, do: " GROUP BY #{group}", else: "") <>
          if(order, do: " ORDER BY #{order}", else: "") <>
          limit
      )
    end
  end

  # What filters, sorts and pagination wrap a statement in.
  defp wrapper do
    member_of([
      & &1,
      &"SELECT * FROM (#{&1}) AS lotus_sub LIMIT $1 OFFSET $2",
      &~s|WITH _base AS (#{&1}) SELECT * FROM _base WHERE "name" = $2|,
      &~s|WITH _sorted AS (#{&1}) SELECT * FROM _sorted ORDER BY "name" DESC|
    ])
  end

  # A way to return or reveal the protected column under another name.
  defp violation(alias) do
    bind(ssn(alias), fn ssn ->
      member_of([
        {:item, "#{ssn} AS x"},
        {:item, "#{ssn} x"},
        {:item, "upper(#{ssn})"},
        {:item, "#{ssn} || '' AS x"},
        {:item, "#{ssn}::text"},
        {:item, "CAST(#{ssn} AS text) AS x"},
        {:item, "coalesce(#{ssn}, '')"},
        {:item, "(#{ssn})"},
        {:item, "row_number() OVER (ORDER BY #{ssn}) AS n"},
        {:item, "(SELECT #{ssn} FROM users LIMIT 1) AS x"},
        {:where, "#{ssn} = '123'"},
        {:where, "#{ssn} LIKE '1%'"},
        {:where, "id IN (SELECT #{ssn} FROM users)"},
        {:order, "#{ssn}"},
        {:order, "#{ssn} DESC"},
        {:group, "#{ssn}"},
        {:distinct_on, "#{ssn}"},
        {:position, ssn}
      ])
    end)
  end

  defp unsafe_statement do
    gen all(
          {table, alias} <- users_table(),
          items <- list_of(safe_item(alias), max_length: 3),
          {kind, text} <- violation(alias),
          where <- one_of([constant([]), list_of(condition(alias), max_length: 2)]),
          at <- integer(0..length(items)),
          sort <- member_of(["ORDER BY", "GROUP BY"]),
          wrap <- wrapper()
        ) do
      items = Enum.map(items, &elem(&1, 0))
      {items, where, tail} = place(kind, text, items, where, at, sort)

      items = if items == [], do: ["name"], else: items

      wrap.(
        "SELECT #{Enum.join(items, ", ")} FROM #{table}" <>
          if(where == [], do: "", else: " WHERE " <> Enum.join(where, " AND ")) <> tail
      )
    end
  end

  defp place(:item, text, items, where, at, _sort),
    do: {List.insert_at(items, at, text), where, ""}

  defp place(:where, text, items, where, _at, _sort), do: {items, where ++ [text], ""}
  defp place(:order, text, items, where, _at, _sort), do: {items, where, " ORDER BY #{text}"}
  defp place(:group, text, items, where, _at, _sort), do: {items, where, " GROUP BY #{text}"}

  defp place(:distinct_on, text, items, where, _at, _sort),
    do: {["DISTINCT ON (#{text}) name" | items], where, ""}

  defp place(:position, ssn, items, where, at, sort) do
    items = List.insert_at(items, at, ssn)
    {items, where, " #{sort} #{at + 1}"}
  end

  # A statement over `users u JOIN orders o` that reads `ssn` through `ref`
  # renamed, wrapped, filtered, sorted or grouped by, or sorted by its
  # position, at least once.
  defp joined_statement(ref) do
    uses = [
      "SELECT #{ref} AS order_ssn, u.name FROM",
      "SELECT upper(#{ref}), u.name FROM",
      "SELECT #{ref} || '' AS x FROM"
    ]

    tails = [" WHERE #{ref} = '1'", " ORDER BY #{ref} DESC", " GROUP BY #{ref}, u.name"]
    neutral = ["", " WHERE u.id > 1 ORDER BY u.name"]

    head_tail =
      one_of([
        tuple({member_of(uses), member_of(tails ++ neutral)}),
        tuple({constant("SELECT u.name FROM"), member_of(tails)}),
        tuple({constant("SELECT #{ref}, u.name FROM"), member_of([" ORDER BY 1" | tails])})
      ])

    gen all(
          {use, tail} <- head_tail,
          join <-
            member_of([
              "users u JOIN orders o ON o.user_id = u.id",
              "orders o JOIN users u ON u.id = o.user_id",
              "orders AS o LEFT JOIN public.users u ON u.id = o.user_id",
              "users u, orders o"
            ])
        ) do
      "#{use} #{join}#{tail}"
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "a protected column selected as is, with filters and sorts on other columns, passes" do
    check all(sql <- safe_statement(), max_runs: @runs) do
      assert run(sql) == :ok, sql
    end
  end

  property "a protected column renamed, wrapped, filtered, sorted, grouped or sorted by position is refused" do
    check all(sql <- unsafe_statement(), max_runs: @runs) do
      assert {:error, _} = run(sql), sql
    end
  end

  property "the same column of a relation without a policy may be used freely" do
    check all(
            ref <- member_of(["o.ssn", ~s(o."ssn"), "O.SSN"]),
            sql <- joined_statement(ref),
            max_runs: @runs
          ) do
      assert run(sql, @joined) == :ok, sql
    end
  end

  property "the protected column, qualified or not, is still refused next to it" do
    # `orders.ssn` names nothing once `orders` has an alias, so it is taken
    # for any table's column.
    check all(
            ref <- member_of(["u.ssn", "ssn", "users.ssn", ~s(u."ssn"), "orders.ssn"]),
            sql <- joined_statement(ref),
            max_runs: @runs
          ) do
      assert {:error, _} = run(sql, @joined), sql
    end
  end

  # ---------------------------------------------------------------------------
  # Differential: the check before and after
  # ---------------------------------------------------------------------------

  # Every statement the unit tests of the check, of preflight and of the
  # SQL rewriters use.
  @corpus_files [
                  "test/lotus/preflight/columns_test.exs",
                  "test/lotus/column_policy_usage_test.exs"
                ] ++
                  Path.wildcard("test/lotus/preflight_*_test.exs") ++
                  Path.wildcard("test/lotus/sql/*_test.exs")

  @corpus @corpus_files
          |> Enum.flat_map(fn file ->
            file
            |> File.read!()
            |> Code.string_to_quoted!()
            |> Macro.prewalk([], fn
              sql, acc when is_binary(sql) ->
                if sql =~ ~r/^\s*(SELECT|WITH|TABLE)\b/i, do: {sql, [sql | acc]}, else: {sql, acc}

              node, acc ->
                {node, acc}
            end)
            |> elem(1)
          end)
          |> Enum.uniq()

  for file <- @corpus_files, do: @external_resource(file)

  # Before, a sort by position passed, and so did `TABLE t` in a set
  # operation and a NATURAL join; now they may be refused. Those are the
  # only differences between the two checks over `users` alone: a qualifier
  # can only resolve to `users` then, whose `ssn` is protected either way.
  defp agree?(_sql, _old, {:error, "Query sorts or groups by position " <> _}), do: true
  defp agree?(_sql, _old, {:error, "Query joins with NATURAL " <> _}), do: true

  defp agree?(sql, old, {:error, "Query combines * with UNION" <> _} = new),
    do: old == new or sql =~ ~r/table/i

  defp agree?(_sql, old, new), do: old == new

  defp assert_agree(sql) do
    for profile <- [@postgres, @mysql] do
      old = OldColumns.check(sql, profile, @matcher, @users)
      new = Columns.check(sql, profile, @matcher, @users)
      assert agree?(sql, old, new), "#{sql}\nold: #{inspect(old)}\nnew: #{inspect(new)}"

      assert Columns.table_names(sql, profile) == OldColumns.table_names(sql, profile), sql
    end
  end

  test "the corpus has the unit tests' statements" do
    assert length(@corpus) > 200
  end

  test "agrees with the old check on the corpus" do
    Enum.each(@corpus, &assert_agree/1)
  end

  test "differs from the old check where it now refuses a sort by position" do
    assert OldColumns.check("SELECT ssn FROM users ORDER BY 1", @postgres, @matcher, @users) ==
             :ok

    assert {:error, "Query sorts or groups by position 1, " <> _} =
             run("SELECT ssn FROM users ORDER BY 1")
  end

  property "agrees with the old check on generated statements" do
    check all(sql <- one_of([safe_statement(), unsafe_statement()]), max_runs: @runs) do
      assert_agree(sql)
    end
  end

  @vocabulary String.split(~S"""
              SELECT select FROM from WHERE ORDER GROUP BY AS as JOIN ON USING WITH RECURSIVE
              UNION EXCEPT LIMIT OFFSET DISTINCT ALL TABLE LATERAL ONLY HAVING WINDOW OVER
              ROLLUP CUBE GROUPING SETS ASC DESC NULLS ssn SSN name users USERS u o orders
              public to_json row upper generate_series count g t x 0 1 2 3 10 1.5 1e3 . . , ,
              ( ( ) ) * ; :: + = || $1 'x' 'ssn' "ssn" "u" "Users" `ssn` U&"x" -- /* */ {{v}}
              [[ ]] é Ü
              """)

  defp soup do
    gen all(
          words <- list_of(member_of(@vocabulary), max_length: 30),
          seps <- list_of(member_of([" ", " ", "", "\n"]), length: length(words))
        ) do
      words |> Enum.zip(seps) |> Enum.map_join(fn {word, sep} -> word <> sep end)
    end
  end

  property "agrees with the old check on token soup" do
    check all(sql <- soup(), max_runs: @runs * 4) do
      assert_agree(sql)
    end
  end

  property "agrees with the old check on random ASCII" do
    check all(sql <- string(:ascii, max_length: 60), max_runs: @runs * 2) do
      assert_agree("SELECT " <> sql <> " FROM users")
    end
  end
end
