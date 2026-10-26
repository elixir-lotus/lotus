# Measures Lotus.Query.Tokenizer.tokenize/2 on mixed SQL of growing size.
#
#     mix run bench/tokenizer.exs
#     SIZES=1kb,100kb mix run bench/tokenizer.exs
#
# Each input repeats a dialect-specific fragment that mixes code, strings,
# quoted identifiers, comments, placeholders and optional blocks until it
# reaches the target size. The "10mb-literal" case is a 10 MB statement
# whose first half is one 5 MB string literal. Timings are the median of
# several warm runs (fewer for the large inputs), each in a fresh process.

alias Lotus.Query.Tokenizer
alias Lotus.Query.Tokenizer.Profile

fragments = %{
  "sql:postgres" => """
  SELECT u.id, u."Display Name", 'O''Brien; {{x}}' AS s, E'it\\'s' AS e, $$body; 'q'$$ AS d
  FROM public.users u -- trailing comment with {{ignored}}
  /* block /* nested */ comment */ WHERE u.id = {{user_id}} AND tags[1] = 'a'
  [[AND u.status = {{status}}]] AND ARRAY[[1,2],[3,4]] @> x AND y = $1 ünïcødé
  """,
  "sql:mysql" => """
  SELECT u.id, `Display Name`, 'O\\'Brien; {{x}}' AS s, "dq ""x\""" AS d
  FROM users u -- trailing comment with {{ignored}}
  # hash comment
  /* block comment */ /*!50000 STRAIGHT_JOIN */ WHERE u.id = {{user_id}} AND 5--1
  [[AND u.status = {{status}}]] AND z = 'ünïcødé'
  """,
  "sql:sqlite" => """
  SELECT u.id, "Display Name", [bracket name], `tick`, 'O''Brien; {{x}}' AS s
  FROM users u -- trailing comment with {{ignored}}
  /* block comment */ WHERE u.id = {{user_id}}
  [[AND u.status = {{status}}]] AND z = 'ünïcødé'
  """
}

sizes = [
  {"1kb", 1_000},
  {"100kb", 100_000},
  {"1mb", 1_000_000},
  {"10mb", 10_000_000}
]

wanted =
  case System.get_env("SIZES") do
    nil -> nil
    list -> String.split(list, ",")
  end

sizes = if wanted, do: Enum.filter(sizes, fn {name, _} -> name in wanted end), else: sizes

build = fn fragment, target ->
  copies = div(target, byte_size(fragment)) + 1
  fragment |> String.duplicate(copies) |> binary_part(0, target)
end

runs_for = fn
  size when size <= 1_000 -> 2_000
  size when size <= 100_000 -> 50
  size when size <= 1_000_000 -> 10
  _ -> 3
end

median = fn times ->
  sorted = Enum.sort(times)
  Enum.at(sorted, div(length(sorted), 2))
end

# Each run happens in a fresh process, as a request would, so one run's
# garbage does not slow the next.
run_once = fn input, profile ->
  {pid, ref} =
    spawn_monitor(fn ->
      exit({:ok, elem(:timer.tc(fn -> Tokenizer.tokenize(input, profile) end), 0)})
    end)

  receive do
    {:DOWN, ^ref, :process, ^pid, {:ok, us}} -> us
    {:DOWN, ^ref, :process, ^pid, reason} -> raise "tokenize failed: #{inspect(reason)}"
  end
end

measure = fn input, profile, runs ->
  # Warm up once, then time each run on its own.
  run_once.(input, profile)
  median.(for _ <- 1..runs, do: run_once.(input, profile))
end

format = fn us ->
  cond do
    us < 1_000 -> "#{us} µs"
    us < 1_000_000 -> "#{Float.round(us / 1_000, 2)} ms"
    true -> "#{Float.round(us / 1_000_000, 2)} s"
  end
end

IO.puts("| profile | size | median |")
IO.puts("|---|---|---|")

for {language, fragment} <- Enum.sort(fragments), {name, size} <- sizes do
  profile = Profile.for_language(language)
  input = build.(fragment, size)
  us = measure.(input, profile, runs_for.(size))
  IO.puts("| #{language} | #{name} | #{format.(us)} |")
end

if wanted == nil or "10mb-literal" in wanted do
  literal = "SELECT '" <> String.duplicate("a{{b}}''; ", 500_000) <> "' AS x, {{y}} "
  filler = build.(fragments["sql:postgres"], 10_000_000 - byte_size(literal))
  input = literal <> filler

  for language <- Enum.sort(Map.keys(fragments)) do
    us = measure.(input, Profile.for_language(language), 3)
    IO.puts("| #{language} | 10mb-literal | #{format.(us)} |")
  end
end
