# Measures visibility checks with a raw rule set per check against one
# compiled matcher per result.
#
#     mix run bench/visibility_matcher.exs
#
# A raw rule set is compiled on every check, which is what a check by source
# name cost before the matcher existed. A regex rule still runs once per
# column or relation in both cases, so the gain is largest for exact names.

alias Lotus.Visibility

iterations = 2_000
relations = [{"public", "users"}, {"public", "orders"}]
columns = for i <- 1..60, do: "column_#{i}"

regex_rules = %{
  column: [
    {"public", "users", "password", [mask: :sha256]},
    {"public", "users", ~r/^api_/, :omit},
    {"users", "ssn", :error},
    {"orders", ~r/_token$/, :omit},
    {~r/^card_/, [mask: {:partial, keep_last: 4}]},
    {~r/_secret$/, :omit},
    {~r/^internal_/, :omit},
    {"email", [mask: {:partial, keep_first: 2, keep_domain: true}]},
    {"phone", [mask: {:partial, keep_last: 4}]},
    {"password_hash", :error},
    {"tax_id", :omit},
    {~r/^pii_/, [mask: :sha256]}
  ]
}

exact_names =
  ~w(password password_hash ssn tax_id api_key api_secret card_number phone email salary iban internal_note)

exact_rules = %{column: Enum.map(exact_names, &{&1, :omit})}

table_rules = %{
  schema: [allow: ["public", "reporting", ~r/^tenant_/], deny: ["legacy"]],
  table: [
    allow: [{"public", ~r/^dim_/}, {"public", ~r/^fact_/}, {"reporting", ~r/.*/}],
    deny: ["api_keys", "user_passwords", {~r/^tenant_/, "audit_logs"}]
  ]
}

many_relations = for i <- 1..20, do: {"public", "dim_#{i}"}

measure = fn fun ->
  {micros, :ok} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
  micros / iterations
end

report = fn label, raw, compiled ->
  IO.puts(
    "#{label}: raw #{Float.round(raw, 1)} µs, matcher #{Float.round(compiled, 1)} µs, " <>
      "#{Float.round(raw / compiled, 1)}x"
  )
end

scenario = fn label, rules, items, check ->
  raw = measure.(fn -> Enum.each(items, &check.(rules, &1)) end)

  compiled =
    measure.(fn ->
      matcher = Visibility.compile(rules)
      Enum.each(items, &check.(matcher, &1))
    end)

  report.(label, raw, compiled)
end

IO.puts("#{iterations} results, #{length(columns)} columns, #{length(many_relations)} relations")

scenario.("12 column rules, 7 regex", regex_rules, columns, fn source, column ->
  Visibility.column_policy_for(source, relations, column)
end)

scenario.("12 column rules, all exact", exact_rules, columns, fn source, column ->
  Visibility.column_policy_for(source, relations, column)
end)

scenario.("schema and table rules", table_rules, many_relations, fn source, relation ->
  Visibility.allowed_relation?(source, relation)
end)
