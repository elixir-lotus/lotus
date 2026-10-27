defmodule Lotus.Query.Tokenizer.Reference do
  @moduledoc false
  # A slow, deliberately plain implementation of the rules documented in
  # `Lotus.Query.Tokenizer`: it looks at one byte offset at a time, tries
  # every rule in order with random access into a tuple of bytes, and builds
  # tokens from offsets. It shares no code with the tokenizer, so the
  # property tests can compare the two on random input.

  alias Lotus.Query.Tokenizer.Profile

  def tokenize(text, %Profile{} = profile) do
    bytes = text |> :binary.bin_to_list() |> List.to_tuple()
    run(text, bytes, profile, MapSet.new())
  end

  # An unclosed `[[` is plain code: rerun with those openers disabled.
  defp run(text, bytes, profile, disabled) do
    initial = %{i: 0, start: 0, acc: [], depth: 0, stack: []}

    case walk(text, bytes, profile, disabled, initial) do
      {:ok, tokens} -> tokens
      {:unclosed, openers} -> run(text, bytes, profile, MapSet.union(disabled, openers))
    end
  end

  defp walk(text, bytes, _profile, _disabled, %{i: i} = st) when i >= tuple_size(bytes) do
    st = flush(text, st, i)

    case st.stack do
      [] -> {:ok, Enum.reverse(st.acc)}
      stack -> {:unclosed, MapSet.new(stack, & &1.opener)}
    end
  end

  defp walk(text, bytes, profile, disabled, st) do
    text |> rule(bytes, profile, disabled, st) |> then(&walk(text, bytes, profile, disabled, &1))
  end

  # Lotus syntax first, then the regions in their documented precedence.
  defp rule(text, b, p, disabled, %{i: i} = st) do
    case at(b, i) do
      ?{ -> brace(text, b, st)
      ?[ -> open_bracket(text, b, p, disabled, st)
      ?] -> close_bracket(text, b, st)
      _ -> region_rule(text, b, p, st)
    end
  end

  defp brace(text, b, %{i: i} = st) do
    cond do
      len = placeholder(b, i) ->
        name = binary_part(text, i + 2, len - 4)
        token(text, st, i, i + len, fn raw -> {:variable, name, raw} end)

      at(b, i + 1) == ?{ ->
        %{st | i: i + 2}

      true ->
        %{st | i: i + 1}
    end
  end

  defp open_bracket(text, b, p, disabled, %{i: i} = st) do
    double? = at(b, i + 1) == ?[

    cond do
      double? and MapSet.member?(disabled, i) ->
        %{st | i: i + 2}

      double? and opens_block?(b, p, st, i) ->
        st = flush(text, st, i)
        frame = %{acc: st.acc, depth: st.depth, opener: i}
        %{st | i: i + 2, start: i + 2, acc: [], depth: 0, stack: [frame | st.stack]}

      brackets?(p) ->
        stop = find(b, i + 1, fn j -> at(b, j) == ?] end)
        region(text, st, :identifier, i, if(stop, do: stop + 1, else: tuple_size(b)))

      true ->
        %{st | i: i + 1, depth: st.depth + 1}
    end
  end

  defp close_bracket(text, b, %{i: i} = st) do
    cond do
      st.depth > 0 ->
        %{st | i: i + 1, depth: st.depth - 1}

      at(b, i + 1) == ?] and st.stack != [] ->
        st = flush(text, st, i)
        [frame | stack] = st.stack
        block = {:block, Enum.reverse(st.acc)}
        %{st | i: i + 2, start: i + 2, acc: [block | frame.acc], depth: frame.depth, stack: stack}

      true ->
        %{st | i: i + 1}
    end
  end

  defp region_rule(text, b, p, %{i: i} = st) do
    cond do
      marker = Enum.find(p.line_comments, &starts?(b, i, &1)) ->
        line_comment(text, b, p, st, marker)

      block_comment?(b, p, i) ->
        block_comment(text, b, p, st)

      quote = Enum.find(p.string_quotes, &starts?(b, i, &1)) ->
        escapes? = escapes?(b, p, i, quote)
        region(text, st, :string, i, quoted_end(b, i + 1, :binary.first(quote), escapes?))

      quote = Enum.find(p.identifier_quotes -- ["["], &starts?(b, i, &1)) ->
        region(text, st, :identifier, i, quoted_end(b, i + 1, :binary.first(quote), false))

      tag_end = dollar_tag_end(b, p, i) ->
        delimiter = binary_part(text, i, tag_end - i)
        found = find(b, tag_end, fn j -> starts?(b, j, delimiter) end)
        stop = if found, do: found + byte_size(delimiter), else: tuple_size(b)
        region(text, st, :string, i, stop)

      true ->
        %{st | i: i + 1}
    end
  end

  defp brackets?(p), do: p.bracket_identifiers? or "[" in p.identifier_quotes

  defp block_comment?(b, p, i), do: p.block_comments? and starts?(b, i, "/*")

  defp escapes?(_b, %{backslash_escapes?: true}, _i, _quote), do: true

  defp escapes?(b, p, i, quote) do
    p.escape_string_prefix? and quote == "'" and at(b, i - 1) in [?E, ?e] and
      not ident?(at(b, i - 2))
  end

  defp line_comment(text, b, p, %{i: i} = st, marker) do
    next = at(b, i + 2)

    if marker == "--" and p.dash_comment_needs_space? and next != nil and next > 32 and
         next != 127 do
      %{st | i: i + 1}
    else
      stop =
        find(b, i + byte_size(marker), fn j ->
          at(b, j) == ?\n or (p.line_comment_ends_at_cr? and at(b, j) == ?\r)
        end)

      region(text, st, :comment, i, stop || tuple_size(b))
    end
  end

  defp block_comment(text, b, p, %{i: i} = st) do
    cond do
      p.executable_comments? and at(b, i + 2) == ?! ->
        %{st | i: i + 3}

      p.executable_comments? and at(b, i + 2) == ?M and at(b, i + 3) == ?! ->
        %{st | i: i + 4}

      true ->
        region(text, st, :comment, i, comment_end(b, i + 2, 1, p.nested_block_comments?))
    end
  end

  defp comment_end(b, j, depth, nested?) do
    cond do
      j >= tuple_size(b) -> tuple_size(b)
      starts?(b, j, "*/") and depth == 1 -> j + 2
      starts?(b, j, "*/") -> comment_end(b, j + 2, depth - 1, nested?)
      nested? and starts?(b, j, "/*") -> comment_end(b, j + 2, depth + 1, nested?)
      true -> comment_end(b, j + 1, depth, nested?)
    end
  end

  defp quoted_end(b, j, quote, escapes?) do
    cond do
      j >= tuple_size(b) -> tuple_size(b)
      escapes? and at(b, j) == ?\\ -> quoted_end(b, min(j + 2, tuple_size(b)), quote, escapes?)
      at(b, j) == quote and at(b, j + 1) == quote -> quoted_end(b, j + 2, quote, escapes?)
      at(b, j) == quote -> j + 1
      true -> quoted_end(b, j + 1, quote, escapes?)
    end
  end

  # The offset after the `$` that closes the tag of a dollar quote at `i`,
  # or nil when no dollar quote starts at `i`.
  defp dollar_tag_end(_b, %{dollar_quotes?: false}, _i), do: nil

  defp dollar_tag_end(b, _p, i) do
    stop = find(b, i + 1, fn j -> not tag_byte?(at(b, j)) end)

    cond do
      at(b, i) != ?$ or ident?(at(b, i - 1)) -> nil
      stop == nil or at(b, stop) != ?$ -> nil
      stop == i + 1 -> stop + 1
      at(b, i + 1) in ?0..?9 -> nil
      true -> stop + 1
    end
  end

  defp placeholder(b, i) do
    with true <- at(b, i) == ?{ and at(b, i + 1) == ?{,
         first when first in ?a..?z or first in ?A..?Z or first == ?_ <- at(b, i + 2),
         stop when is_integer(stop) <- find(b, i + 3, fn j -> not name_byte?(at(b, j)) end),
         true <- at(b, stop) == ?} and at(b, stop + 1) == ?} do
      stop + 2 - i
    else
      _ -> nil
    end
  end

  defp block_opener?(b, i) do
    word_end = back_over_whitespace(b, i)

    after_array? =
      word_end >= 5 and
        String.downcase(List.to_string(for j <- (word_end - 5)..(word_end - 1), do: at(b, j))) ==
          "array" and not ident?(at(b, word_end - 6))

    not ident?(at(b, i - 1)) and not after_array?
  end

  defp opens_block?(b, p, st, i),
    do: (st.depth == 0 and block_opener?(b, i)) or (p.json_blocks? and after_value?(b, i))

  # JSON: the byte before the `[[`, whitespace aside, ends a value.
  defp after_value?(b, i) do
    j = back_over_whitespace(b, i)

    j > 0 and
      (at(b, j - 1) in [?}, ?], ?"] or at(b, j - 1) in ?0..?9 or at(b, j - 1) in ?a..?z or
         at(b, j - 1) in ?A..?Z)
  end

  defp back_over_whitespace(b, i) do
    if i > 0 and at(b, i - 1) in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v],
      do: back_over_whitespace(b, i - 1),
      else: i
  end

  defp region(text, st, kind, from, stop), do: token(text, st, from, stop, &{kind, &1})

  defp token(text, st, from, stop, build) do
    st = flush(text, st, from)
    %{st | i: stop, start: stop, acc: [build.(binary_part(text, from, stop - from)) | st.acc]}
  end

  defp flush(text, %{start: start} = st, stop) when stop > start,
    do: %{st | acc: [{:code, binary_part(text, start, stop - start)} | st.acc], start: stop}

  defp flush(_text, st, _stop), do: st

  defp find(b, j, pred) do
    cond do
      j >= tuple_size(b) -> nil
      pred.(j) -> j
      true -> find(b, j + 1, pred)
    end
  end

  defp starts?(b, i, marker) do
    marker
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.all?(fn {byte, k} -> at(b, i + k) == byte end)
  end

  defp at(b, j) when j >= 0 and j < tuple_size(b), do: elem(b, j)
  defp at(_b, _j), do: nil

  defp ident?(nil), do: false

  defp ident?(byte),
    do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?$] or byte >= 128

  defp name_byte?(nil), do: false
  defp name_byte?(byte), do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_

  defp tag_byte?(nil), do: false
  defp tag_byte?(byte), do: name_byte?(byte) or byte >= 128
end

defmodule Lotus.Query.Tokenizer.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Query.Tokenizer.Reference

  # Raise with TOKENIZER_PROPERTY_RUNS for a longer soak.
  @runs String.to_integer(System.get_env("TOKENIZER_PROPERTY_RUNS", "1500"))

  @profiles [
    {"sql", Profile.for_language("sql")},
    {"sql:postgres", Profile.for_language("sql:postgres")},
    {"sql:mysql", Profile.for_language("sql:mysql")},
    {"sql:sqlite", Profile.for_language("sql:sqlite")},
    {"json:elasticsearch", Profile.for_language("json:elasticsearch")},
    {"sql + dialect spec",
     Profile.from_dialect_spec(Profile.for_language("sql"), %{
       hash_comments: true,
       slash_comments: true,
       identifier_quotes: "`\"",
       space_after_dashes: true
     })},
    {"hand-built profile",
     %Profile{
       string_quotes: ["'", "~"],
       identifier_quotes: ["|"],
       line_comments: [";;", "--"],
       nested_block_comments?: true,
       dollar_quotes?: true,
       backslash_escapes?: true,
       bracket_identifiers?: true,
       dash_comment_needs_space?: true
     }}
  ]

  # Pieces weighted towards delimiters and the bytes around them.
  defp sql_piece do
    frequency([
      {6, member_of(~w(' " ` $ [ ] { } / * - # ; ! M + E e U & ^ ~ | \\ ))},
      {3, member_of([" ", "\n", "\r", "\t", "a", "x", "_", "1", "9", "é", "€", <<0xFF>>])},
      {2,
       member_of([
         "{{a}}",
         "{{_x1}}",
         "{{",
         "}}",
         "[[",
         "]]",
         "--",
         "-- ",
         "/*",
         "*/",
         "/*!",
         "/*M!",
         "/*+",
         "$$",
         "$t$",
         "$é$",
         "''",
         "E'",
         "U&'",
         "ARRAY",
         "array ",
         "\\'",
         "\r\n"
       ])}
    ])
  end

  defp sql_text, do: map(list_of(sql_piece(), max_length: 40), &Enum.join/1)

  for {name, profile} <- @profiles do
    @profile profile

    describe "under #{name}" do
      property "gives the input back" do
        check all(text <- sql_text(), max_runs: @runs) do
          assert text |> Tokenizer.tokenize(@profile) |> Tokenizer.to_string() == text
        end
      end

      property "agrees with the reference implementation" do
        check all(text <- sql_text(), max_runs: @runs) do
          assert Tokenizer.tokenize(text, @profile) == Reference.tokenize(text, @profile)
        end
      end

      property "never returns code from inside a reference string, identifier or comment" do
        check all(text <- sql_text(), max_runs: @runs) do
          hidden = text |> Reference.tokenize(@profile) |> hidden_offsets()
          code = text |> Tokenizer.tokenize(@profile) |> code_offsets()
          assert MapSet.disjoint?(hidden, code)
        end
      end

      property "never raises on arbitrary bytes" do
        check all(text <- binary(max_length: 200), max_runs: @runs) do
          assert text |> Tokenizer.tokenize(@profile) |> Tokenizer.to_string() == text
        end
      end
    end
  end

  # Byte offsets covered by each token kind, walking tokens in order. Block
  # brackets cover two bytes each and belong to neither set.
  defp code_offsets(tokens), do: tokens |> offsets() |> select(&(&1 == :code))

  defp hidden_offsets(tokens),
    do: tokens |> offsets() |> select(&(&1 in [:string, :identifier, :comment]))

  defp select(offsets, keep?) do
    for {kind, offset} <- offsets, keep?.(kind), into: MapSet.new(), do: offset
  end

  defp offsets(tokens) do
    {offsets, _end} = offsets(tokens, 0)
    offsets
  end

  defp offsets(tokens, pos) do
    Enum.flat_map_reduce(tokens, pos, fn
      {:block, inner}, pos ->
        {inner_offsets, pos} = offsets(inner, pos + 2)
        {inner_offsets, pos + 2}

      {:variable, _name, raw}, pos ->
        {for(i <- pos..(pos + byte_size(raw) - 1)//1, do: {:variable, i}), pos + byte_size(raw)}

      {kind, raw}, pos ->
        {for(i <- pos..(pos + byte_size(raw) - 1)//1, do: {kind, i}), pos + byte_size(raw)}
    end)
  end
end
