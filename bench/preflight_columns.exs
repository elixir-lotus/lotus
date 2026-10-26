# Measures `Lotus.Preflight.Columns.check/4` on a small, a medium, a large
# (about 10 KB) and a very large (about 100 KB) statement over a table with
# a protected column.
#
#     mix run bench/preflight_columns.exs
#     MIX_ENV=test mix run bench/preflight_columns.exs   # also the 1.x check
#
# The tokenizer (`Lotus.Query.Tokenizer.tokenize/2`) runs inside each check,
# so its own time is measured too; "columns" is the check's time without it.
# Under MIX_ENV=test, `Lotus.Test.OldColumns` (the check before its rewrite,
# kept in test/support for the differential tests) is measured alongside.
# Each figure is the fastest of 15 rounds of many iterations, in µs (the
# least disturbed by whatever else the machine runs).

alias Lotus.Preflight.Columns
alias Lotus.Query.Tokenizer
alias Lotus.Query.Tokenizer.Profile
alias Lotus.Visibility

matcher = Visibility.compile(%{column: [{"users", "ssn", [action: :mask, mask: :sha256]}]})
profile = Profile.for_language("sql:postgres")
relations = [{"public", "users"}, {"public", "orders"}]
old = Lotus.Test.OldColumns

small =
  "SELECT u.ssn, u.name FROM users u JOIN orders o ON o.user_id = u.id " <>
    "WHERE o.total > 10 AND u.name ILIKE 'a%' ORDER BY u.name LIMIT 100"

medium = """
WITH recent AS (
  SELECT o.user_id, sum(o.total) AS spent, count(*) AS orders_count
  FROM orders o
  WHERE o.inserted_at > now() - interval '30 days' -- last month
  GROUP BY o.user_id
)
SELECT u.ssn, u.name, u.email, r.spent, r.orders_count,
       CASE WHEN r.spent > 1000 THEN 'gold' WHEN r.spent > 100 THEN 'silver' ELSE 'bronze' END AS tier,
       coalesce(u.city, 'unknown') AS city
FROM users u
LEFT JOIN recent r ON r.user_id = u.id
WHERE u.active AND u.name ILIKE $1 AND u.id NOT IN (SELECT user_id FROM orders WHERE total < 0)
ORDER BY r.spent DESC NULLS LAST, u.name
LIMIT 50 OFFSET 0
"""

wide = fn columns ->
  body =
    Enum.map_join(1..columns, fn i ->
      "  u.name AS name_#{i}, lower(u.email) AS email_#{i}, o.total * #{i} AS t_#{i},\n"
    end)

  "SELECT u.ssn,\n" <>
    body <>
    "  u.id\nFROM users u JOIN orders o ON o.user_id = u.id\n" <>
    "WHERE o.total > 10 AND u.name ILIKE 'a%' /* filter */ ORDER BY u.name LIMIT 100"
end

statements = [
  {"small", small, 20_000},
  {"medium", medium, 4_000},
  {"large", wide.(140), 200},
  {"very large", wide.(1_400), 20}
]

measure = fn fun, iterations ->
  Enum.each(1..max(div(iterations, 10), 1), fn _ -> fun.() end)

  rounds =
    for _ <- 1..15 do
      {us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
      us / iterations
    end

  Enum.min(rounds)
end

old? = Code.ensure_loaded?(old)
format = fn us -> String.pad_leading(:erlang.float_to_binary(us, decimals: 1), 12) end

IO.puts(
  String.pad_trailing("statement", 22) <>
    Enum.map_join(
      ["check/4", "tokenize/2", "columns"] ++
        if(old?, do: ["old check/4", "old columns"], else: []),
      &String.pad_leading(&1, 12)
    )
)

for {label, sql, iterations} <- statements do
  :ok = Columns.check(sql, profile, matcher, relations)
  check = measure.(fn -> Columns.check(sql, profile, matcher, relations) end, iterations)
  tokenize = measure.(fn -> Tokenizer.tokenize(sql, profile) end, iterations)

  olds =
    if old? do
      old_iterations = max(div(iterations, 10), 2)
      old_check = measure.(fn -> old.check(sql, profile, matcher, relations) end, old_iterations)
      [old_check, old_check - tokenize]
    else
      []
    end

  IO.puts(
    String.pad_trailing("#{label} (#{byte_size(sql)} B)", 22) <>
      Enum.map_join([check, tokenize, check - tokenize] ++ olds, format)
  )
end
