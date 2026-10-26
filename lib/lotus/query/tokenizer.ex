defmodule Lotus.Query.Tokenizer do
  @moduledoc """
  Splits a statement into template-level regions so that Lotus template
  syntax is only recognized where the query engine would see code.

  The tokenizer is not a parser. It knows the delimiters of string
  literals, quoted identifiers and comments for the target language (see
  `Lotus.Query.Tokenizer.Profile`) and treats everything else as code. It
  recognizes two pieces of Lotus syntax in code: `{{name}}` placeholders and
  `[[...]]` optional blocks.

  ## Tokens

    * `{:code, raw}` — text the engine parses
    * `{:comment, raw}` — a line or block comment, delimiters included. A
      line comment stops before the newline.
    * `{:string, raw}` — a string literal, quotes included
    * `{:identifier, raw}` — a quoted identifier, quotes included
    * `{:variable, name, raw}` — a `{{name}}` placeholder
    * `{:block, tokens}` — a `[[...]]` block with its inner tokens

  Concatenating the raw text of the tokens gives the input back exactly;
  `to_string/1` does that. The raw text of a token is a sub-binary of the
  input, so tokenizing copies nothing.

  Placeholders and blocks inside a string, identifier or comment are not
  recognized. String tokens keep their raw text, so a transform that wants
  to see `'{{x}}'` or `'%{{x}}%'` can still inspect the literal.

  ## Lexical rules

  The scanner works on bytes: every delimiter below is ASCII, and UTF-8
  continuation bytes never equal an ASCII byte, so multi-byte characters
  pass through untouched and invalid UTF-8 never raises. It runs in linear
  time without deep recursion. Which rules apply depends on the profile:

    * **Strings.** Each of the profile's `string_quotes` opens a literal that
      the same quote closes. A doubled quote (`'O''Brien'`) stays inside.
      With `backslash_escapes?` (MySQL, JSON) a backslash also escapes the
      next byte (`'it\\'s'`); a trailing backslash runs to the end.
    * **Escape strings.** With `escape_string_prefix?` (PostgreSQL), a `'`
      directly after a standalone `E` or `e` opens an escape string, where a
      backslash escapes the next byte even though plain strings have no
      escapes. The `E` is standalone when the byte before it is not an
      identifier character, so `nameE'x'` is not an escape string. The
      prefix stays in the preceding code token. Other prefixes (`U&'...'`,
      `N'...'`, `X'...'`, `B'...'`, MySQL's `_utf8mb4'...'`) need nothing
      special: the literal is an ordinary string after the prefix.
    * **Quoted identifiers.** Each of the profile's `identifier_quotes` opens
      an identifier that the same quote closes; a doubled quote stays
      inside (`"a""b"`, `` `a``b` ``). Backslashes never escape.
    * **Bracket identifiers.** With `bracket_identifiers?` (SQLite), a
      single `[` opens an identifier that the first `]` closes, with no
      escapes (`[my col]`). A `[[` that opens a Lotus block (below) takes
      precedence; any other `[[` starts a bracket identifier whose name
      begins with `[`.
    * **Dollar quotes.** With `dollar_quotes?` (PostgreSQL), `$$` or
      `$tag$` opens a string that the same delimiter closes. A tag starts
      with a letter, `_` or a non-ASCII byte and goes on with those or
      digits, so `$1` is a parameter. A dollar quote cannot start inside an
      identifier: `$` right after an identifier character (letter, digit,
      `_`, `$`, non-ASCII byte) is code, so `foo$bar$` is one identifier.
    * **Line comments.** Each of the profile's `line_comments` markers
      (`--`, and `#` or `//` where enabled) runs to the end of the line,
      excluding the line break. The line ends at `\\n`; with
      `line_comment_ends_at_cr?` (PostgreSQL) a `\\r` ends it too. With
      `dash_comment_needs_space?` (MySQL) `--` starts a comment only when
      followed by whitespace, a control character or the end of input, so
      `5--1` is code. A line comment at the end of input needs no newline.
    * **Block comments.** With `block_comments?`, `/*` opens a comment that
      the first `*/` closes; with `nested_block_comments?` (PostgreSQL)
      comments nest and each `/*` needs its own `*/`.
    * **Executable comments.** With `executable_comments?` (MySQL), `/*!`,
      `/*!50000` (any version digits) and MariaDB's `/*M!` are not comments:
      MySQL runs their contents, so the opener, the contents and the closing
      `*/` are scanned as code and `code/1` returns them. Optimizer hints
      (`/*+ ... */`) carry no statement text and stay comments.
    * **Unterminated regions.** A string, identifier, dollar quote or block
      comment without its closing delimiter runs to the end of the input.

  ## Lotus syntax

    * **Placeholders.** `{{name}}` in code, where `name` is an ASCII letter
      or `_` followed by letters, digits or `_`. Anything else after `{{`
      (`{{ x }}`, `{{1x}}`) is code.
    * **Optional blocks.** `[[` in code opens a block and `]]` closes the
      innermost open block. Because SQL arrays also use brackets
      (PostgreSQL's `ARRAY[[1,2],[3,4]]`, `arr[1][2]`, `x[y[1]]`), the
      tokenizer tracks the single `[`/`]` brackets of the code at each block
      level and applies these rules:
      * `[[` opens a block only when no single `[` is open at the current
        level, it does not directly follow an identifier character (letter,
        digit, `_`, `$`, non-ASCII byte), and it does not follow the keyword
        `ARRAY` (with only whitespace in between). Otherwise its first `[`
        is a single bracket, so `ARRAY[[1,2],[3,4]]` and `ARRAY [[1]]` are
        code.
      * A single `]` closes the innermost open single `[` of the current
        level. Only when none is open does `]]` close a block, and only
        when a block is open; otherwise `]` is code. So in
        `[[AND x = arr[y[1]]]]` the block ends at the last `]]`.
      * A block that is still open at the end of the input is not a block:
        its `[[` is plain code, and the blocks inside it are kept.

  ## Performance

  The scan is a single pass over the bytes of the input, linear in its
  size, with every loop tail recursive. Code bytes are skipped by a
  function-head jump table that stops only at bytes that can start a
  marker, and string, comment and identifier bodies have their own byte
  loops; one binary match context runs through all of them, so walking the
  input allocates nothing. No regular expression is used. A megabyte of
  dense mixed SQL tokenizes in about 10 ms (`bench/tokenizer.exs`).
  """

  require Record

  alias Lotus.Query.Tokenizer.Profile

  @type token ::
          {:code, String.t()}
          | {:comment, String.t()}
          | {:string, String.t()}
          | {:identifier, String.t()}
          | {:variable, String.t(), String.t()}
          | {:block, [token()]}

  # From this input size on, the calling process's heap is sized for the
  # token list up front (two words per input byte, at most 64 MB) and put
  # back afterwards. Grown step by step instead, the heap would copy every
  # token made so far at each step, which doubles the time on large input.
  @presize_from 65_536
  @presize_max_words 8_388_608

  @doc """
  Tokenizes `text` under the lexical rules of `profile`.

  For a `text` of 64 KB or more, the calling process's minimum heap size is
  raised for the duration of the call and put back afterwards.
  """
  @spec tokenize(String.t(), Profile.t()) :: [token()]
  def tokenize(text, %Profile{} = profile) when is_binary(text) do
    if byte_size(text) >= @presize_from do
      words = min(2 * byte_size(text), @presize_max_words)
      previous = Process.flag(:min_heap_size, words)

      try do
        run(context(text, profile), [])
      after
        Process.flag(:min_heap_size, previous)
      end
    else
      run(context(text, profile), [])
    end
  end

  # A block left open at the end is plain code. Rescanning with those
  # openers disabled gives the same regions and the same pairing for the
  # other blocks, since an unclosed opener never meets a `]]`.
  defp run(ctx, disabled) do
    case scan(ctx, 0, 0, {[], [], 0, disabled}) do
      {:done, tokens} -> tokens
      {:unclosed, openers} -> run(ctx, :lists.merge(disabled, openers))
    end
  end

  @doc """
  Reassembles the exact input text from a token list.
  """
  @spec to_string([token()]) :: String.t()
  def to_string(tokens) when is_list(tokens) do
    tokens |> to_iodata() |> IO.iodata_to_binary()
  end

  @doc """
  Reassembles the input text from a token list as iodata.
  """
  @spec to_iodata([token()]) :: [iodata()]
  def to_iodata(tokens) when is_list(tokens) do
    Enum.map(tokens, fn
      {:block, inner} -> ["[[", to_iodata(inner), "]]"]
      {:variable, _name, raw} -> raw
      {_kind, raw} -> raw
    end)
  end

  @doc """
  Returns the placeholder names in document order.

  Names come from variable tokens and from `{{name}}` occurrences inside
  string literals, descending into blocks. Comments and quoted identifiers
  are skipped. Duplicates are kept.
  """
  @spec variables([token()]) :: [String.t()]
  def variables(tokens) when is_list(tokens) do
    Enum.flat_map(tokens, fn
      {:variable, name, _raw} -> [name]
      {:string, raw} -> string_variables(raw)
      {:block, inner} -> variables(inner)
      _token -> []
    end)
  end

  @doc """
  Returns every code fragment, including those inside blocks.
  """
  @spec code([token()]) :: [String.t()]
  def code(tokens) when is_list(tokens) do
    Enum.flat_map(tokens, fn
      {:code, raw} -> [raw]
      {:block, inner} -> code(inner)
      _token -> []
    end)
  end

  @doc """
  Replaces every placeholder in code and string tokens with the text `fun`
  returns for its name. Comments and quoted identifiers are left alone.
  """
  @spec replace_variables([token()], (String.t() -> String.t())) :: [token()]
  def replace_variables(tokens, fun) when is_list(tokens) and is_function(fun, 1) do
    Enum.map(tokens, fn
      {:variable, name, _raw} ->
        {:code, fun.(name)}

      {:string, raw} ->
        {:string, replace_string_variables(raw, fun)}

      {:block, inner} ->
        {:block, replace_variables(inner, fun)}

      token ->
        token
    end)
  end

  @doc """
  Replaces the first placeholder named `name` in code or string tokens.

  Returns `:error` when no such placeholder is in code or a string.
  """
  @spec replace_first_variable([token()], String.t(), String.t()) :: {:ok, [token()]} | :error
  def replace_first_variable(tokens, name, replacement) when is_list(tokens) do
    replace_first(tokens, name, replacement, [])
  end

  defp replace_first([], _name, _replacement, _acc), do: :error

  defp replace_first([{:variable, name, _raw} | rest], name, replacement, acc) do
    {:ok, Enum.reverse(acc, [{:code, replacement} | rest])}
  end

  defp replace_first([{:string, raw} = token | rest], name, replacement, acc) do
    placeholder = "{{" <> name <> "}}"

    case :binary.match(raw, placeholder) do
      {pos, len} ->
        replaced = [
          binary_part(raw, 0, pos),
          replacement,
          binary_part(raw, pos + len, byte_size(raw) - pos - len)
        ]

        {:ok, Enum.reverse(acc, [{:string, IO.iodata_to_binary(replaced)} | rest])}

      :nomatch ->
        replace_first(rest, name, replacement, [token | acc])
    end
  end

  defp replace_first([{:block, inner} = token | rest], name, replacement, acc) do
    case replace_first(inner, name, replacement, []) do
      {:ok, inner} -> {:ok, Enum.reverse(acc, [{:block, inner} | rest])}
      :error -> replace_first(rest, name, replacement, [token | acc])
    end
  end

  defp replace_first([token | rest], name, replacement, acc) do
    replace_first(rest, name, replacement, [token | acc])
  end

  # ---------------------------------------------------------------------------
  # Placeholders inside string literals
  #
  # The leftmost `{{name}}` wins; after a `{{` that does not start one, the
  # search goes on from the next byte, so `{{{a}}}` holds `{{a}}`.
  # ---------------------------------------------------------------------------

  defp string_variables(raw), do: string_variables(raw, 0, [])

  defp string_variables(raw, from, acc) do
    case next_placeholder(raw, from) do
      {_start, stop, name} -> string_variables(raw, stop, [name | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp replace_string_variables(raw, fun) do
    case next_placeholder(raw, 0) do
      :none -> raw
      found -> raw |> replace_string_variables(fun, 0, found, []) |> IO.iodata_to_binary()
    end
  end

  defp replace_string_variables(raw, fun, from, {start, stop, name}, acc) do
    acc = [fun.(name), binary_part(raw, from, start - from) | acc]
    replace_string_variables(raw, fun, stop, next_placeholder(raw, stop), acc)
  end

  defp replace_string_variables(raw, _fun, from, :none, acc) do
    Enum.reverse(acc, [binary_part(raw, from, byte_size(raw) - from)])
  end

  defp next_placeholder(raw, from) do
    case :binary.match(raw, "{{", scope: {from, byte_size(raw) - from}) do
      {start, 2} ->
        rest = binary_part(raw, start + 2, byte_size(raw) - start - 2)

        case placeholder_length(rest) do
          0 -> next_placeholder(raw, start + 1)
          len -> {start, start + len + 4, :binary.copy(binary_part(rest, 0, len))}
        end

      :nomatch ->
        :none
    end
  end

  # The length of the name in `name}}` at the start of `bin`, or 0.
  defp placeholder_length(<<first, rest::binary>>)
       when first in ?a..?z or first in ?A..?Z or first == ?_,
       do: placeholder_length(rest, 1)

  defp placeholder_length(_bin), do: 0

  defp placeholder_length(<<"}}", _::binary>>, len), do: len

  defp placeholder_length(<<char, rest::binary>>, len)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_,
       do: placeholder_length(rest, len + 1)

  defp placeholder_length(_bin, _len), do: 0

  # ---------------------------------------------------------------------------
  # Context
  #
  # The profile is compiled once per call into a `ctx` record. A profile
  # whose markers are all standard (`'`, `"` and backtick quotes, `--`, `#`
  # and `//` comments, `/*`, `$`) is scanned by `code/5`, whose clauses
  # dispatch on the marker bytes directly; the record says what each
  # marker starts in this profile (`nil` when nothing). Any other profile
  # is scanned by `code_generic/5`, which looks every byte up in
  # `markers`: a 256-tuple of `{tail, kind}` candidates per first byte,
  # where `tail` is the rest of the marker, longest first.
  # ---------------------------------------------------------------------------

  @standard_markers ["'", "\"", "`", "--", "#", "//", "/*", "$", "[", "]", "{{"]

  Record.defrecordp(:ctx, [
    :text,
    :size,
    :generic,
    :markers,
    :squote,
    :dquote,
    :backtick,
    :dash,
    :hash,
    :slashes,
    :block,
    :dollar,
    :escape_prefix,
    :nested,
    :cr,
    :dash_space,
    :executable,
    :brackets
  ])

  defp context(text, %Profile{} = profile) do
    kinds = marker_kinds(profile)
    generic? = Enum.any?(Map.keys(kinds), &(&1 not in @standard_markers))

    ctx(
      text: text,
      size: byte_size(text),
      generic: generic?,
      markers: if(generic?, do: marker_table(kinds)),
      squote: kinds["'"],
      dquote: kinds["\""],
      backtick: kinds["`"],
      dash: kinds["--"],
      hash: kinds["#"],
      slashes: kinds["//"],
      block: kinds["/*"],
      dollar: kinds["$"],
      escape_prefix: profile.escape_string_prefix?,
      nested: profile.nested_block_comments?,
      cr: profile.line_comment_ends_at_cr?,
      dash_space: profile.dash_comment_needs_space?,
      executable: profile.executable_comments?,
      brackets: profile.bracket_identifiers? or "[" in profile.identifier_quotes
    )
  end

  defp marker_table(kinds) do
    entries =
      kinds
      |> Enum.group_by(fn {<<first, _::binary>>, _kind} -> first end)
      |> Enum.map(fn {first, markers} ->
        candidates =
          markers
          |> Enum.sort_by(fn {marker, _kind} -> -byte_size(marker) end)
          |> Enum.map(fn {<<_, tail::binary>>, kind} -> {tail, kind} end)

        {first + 1, candidates}
      end)

    :erlang.make_tuple(256, [], entries)
  end

  # Later entries win when one marker plays two roles, which keeps the
  # precedence of line comment, block comment, string, identifier, dollar.
  defp marker_kinds(profile) do
    [
      if(profile.dollar_quotes?, do: [{"$", :dollar}], else: []),
      for(quote <- profile.identifier_quotes, do: {quote, {:quoted, :identifier, quote, false}}),
      for(
        quote <- profile.string_quotes,
        do: {quote, {:quoted, :string, quote, profile.backslash_escapes?}}
      ),
      if(profile.block_comments?, do: [{"/*", :block_comment}], else: []),
      for(marker <- profile.line_comments, do: {marker, {:line_comment, marker}}),
      [{"]", :close_bracket}, {"{{", :placeholder}]
    ]
    |> List.flatten()
    |> Enum.reject(fn {marker, _kind} -> marker in ["", "["] end)
    |> Map.new()
    |> Map.put("[", :open_bracket)
  end

  # ---------------------------------------------------------------------------
  # Scanner
  #
  # The scanner threads one binary match context through every loop, so it
  # creates no sub-binaries while it walks; `pos` counts bytes alongside.
  # Code is skipped byte by byte with a jump table and stops only at a
  # marker. A region loop tail-calls `close/4` at its end, which emits the
  # token as a sub-binary of the input and resumes in code.
  #
  #   * `start` — where the pending code run starts; it ends at the next token
  #   * `state` — `{acc, stack, depth, disabled}`:
  #     * `acc` — the tokens of the current level, reversed
  #     * `stack` — one `{acc, depth, offset}` frame per open `[[` block
  #     * `depth` — single `[` brackets open at the current level
  #     * `disabled` — sorted offsets of `[[` openers to treat as code
  #   * `frame` — `{kind, at, start, state}`: what a region loop needs to
  #     emit its token, where `at` is the offset of its opening delimiter
  #
  # Every loop is tail recursive, so input size never grows the stack.
  # ---------------------------------------------------------------------------

  defguardp is_ident_byte(byte)
            when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_ or
                   byte == ?$ or byte >= 128

  defguardp is_name_start(byte) when byte in ?a..?z or byte in ?A..?Z or byte == ?_

  defguardp is_name_byte(byte) when is_name_start(byte) or byte in ?0..?9

  defguardp is_tag_start(byte) when is_name_start(byte) or byte >= 128

  # Restarts the scan at `pos` of the input.
  defp scan(ctx, pos, start, state) do
    ctx(text: text) = ctx
    <<_::binary-size(^pos), bin::binary>> = text
    resume(bin, pos, ctx, start, state)
  end

  defp resume(<<_::binary>> = bin, pos, ctx(generic: false) = ctx, start, state),
    do: code(bin, pos, ctx, start, state)

  defp resume(bin, pos, ctx, start, state), do: code_generic(bin, pos, ctx, start, state)

  defp code(<<"{{", rest::binary>>, pos, ctx, start, state),
    do: name_start(rest, pos + 2, ctx, pos, start, state)

  defp code(<<?[, rest::binary>>, pos, ctx, start, state),
    do: step(rest, :open_bracket, pos, ctx, start, state)

  defp code(<<?], rest::binary>>, pos, ctx, start, state),
    do: step(rest, :close_bracket, pos, ctx, start, state)

  defp code(<<?', rest::binary>>, pos, ctx(squote: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<?", rest::binary>>, pos, ctx(dquote: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<?`, rest::binary>>, pos, ctx(backtick: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<"--", rest::binary>>, pos, ctx(dash: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<?#, rest::binary>>, pos, ctx(hash: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<"//", rest::binary>>, pos, ctx(slashes: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<"/*", rest::binary>>, pos, ctx(block: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<?$, rest::binary>>, pos, ctx(dollar: kind) = ctx, start, state) when kind != nil,
    do: step(rest, kind, pos, ctx, start, state)

  defp code(<<_, rest::binary>>, pos, ctx, start, state),
    do: code(rest, pos + 1, ctx, start, state)

  defp code(<<>>, _pos, ctx, start, state), do: finish(ctx, start, state)

  defp code_generic(<<byte, rest::binary>>, pos, ctx(markers: markers) = ctx, start, state)
       when elem(markers, byte) != [],
       do: candidates(rest, elem(markers, byte), pos, ctx, start, state)

  defp code_generic(<<_, rest::binary>>, pos, ctx, start, state),
    do: code_generic(rest, pos + 1, ctx, start, state)

  defp code_generic(<<>>, _pos, ctx, start, state), do: finish(ctx, start, state)

  defp finish(ctx(size: size) = ctx, start, {acc, [], _depth, _disabled}) do
    {:done, ctx |> flush(start, size, acc) |> Enum.reverse()}
  end

  defp finish(_ctx, _start, {_acc, stack, _depth, _disabled}) do
    {:unclosed, stack |> Enum.map(fn {_acc, _depth, offset} -> offset end) |> Enum.reverse()}
  end

  defp flush(_ctx, start, stop, acc) when stop <= start, do: acc

  defp flush(ctx(text: text), start, stop, acc),
    do: [{:code, binary_part(text, start, stop - start)} | acc]

  defp push(<<_::binary>> = rest, token, at, stop, ctx, start, {acc, stack, depth, disabled}) do
    acc = [token | flush(ctx, start, at, acc)]
    resume(rest, stop, ctx, stop, {acc, stack, depth, disabled})
  end

  # A region from `at` to `stop` ends; `rest` follows it.
  defp close(<<_::binary>> = rest, stop, ctx(text: text) = ctx, {kind, at, start, state}),
    do: push(rest, {kind, binary_part(text, at, stop - at)}, at, stop, ctx, start, state)

  # The byte at `at` may start one of the `candidates` markers; `rest`
  # follows it.
  defp candidates(<<_::binary>> = rest, [{"", kind} | _more], at, ctx, start, state),
    do: step(rest, kind, at, ctx, start, state)

  defp candidates(rest, [{tail, kind} | more], at, ctx, start, state) do
    size = byte_size(tail)

    case rest do
      <<^tail::binary-size(^size), after_marker::binary>> ->
        step(after_marker, kind, at, ctx, start, state)

      _ ->
        candidates(rest, more, at, ctx, start, state)
    end
  end

  defp candidates(rest, [], at, ctx, start, state), do: resume(rest, at + 1, ctx, start, state)

  # `bin` follows the marker, which starts at `at`.
  defp step(<<_::binary>> = bin, :placeholder, at, ctx, start, state),
    do: name_start(bin, at + 2, ctx, at, start, state)

  defp step(bin, {:quoted, kind, quote, escapes?}, at, ctx, start, state) do
    escapes? =
      escapes? or
        (kind == :string and quote == "'" and ctx(ctx, :escape_prefix) and
           escape_prefixed?(ctx, at))

    frame = {kind, at, start, state}

    case quote do
      <<byte>> -> quoted(bin, at + 1, byte, escapes?, ctx, frame)
      _ -> quoted_wide(bin, at + byte_size(quote), quote, escapes?, ctx, frame)
    end
  end

  defp step(
         <<byte, _::binary>>,
         {:line_comment, "--"},
         at,
         ctx(dash_space: true) = ctx,
         start,
         state
       )
       when byte > 32 and byte != 127,
       do: scan(ctx, at + 1, start, state)

  defp step(bin, {:line_comment, marker}, at, ctx(cr: cr?) = ctx, start, state),
    do: line(bin, at + byte_size(marker), cr?, ctx, {:comment, at, start, state})

  defp step(<<?!, rest::binary>>, :block_comment, at, ctx(executable: true) = ctx, start, state),
    do: resume(rest, at + 3, ctx, start, state)

  defp step(
         <<?M, ?!, rest::binary>>,
         :block_comment,
         at,
         ctx(executable: true) = ctx,
         start,
         state
       ),
       do: resume(rest, at + 4, ctx, start, state)

  defp step(bin, :block_comment, at, ctx(nested: true) = ctx, start, state),
    do: nested_comment(bin, at + 2, 1, ctx, {:comment, at, start, state})

  defp step(bin, :block_comment, at, ctx, start, state),
    do: block_comment(bin, at + 2, ctx, {:comment, at, start, state})

  defp step(bin, :dollar, at, ctx, start, state) do
    if ident_byte?(byte_at(ctx, at - 1)),
      do: resume(bin, at + 1, ctx, start, state),
      else: dollar_tag(bin, at + 1, ctx, {:string, at, start, state})
  end

  defp step(
         <<?[, rest::binary>> = bin,
         :open_bracket,
         at,
         ctx,
         start,
         {acc, stack, depth, disabled} = state
       ) do
    cond do
      match?([^at | _], disabled) ->
        resume(rest, at + 2, ctx, start, {acc, stack, depth, tl(disabled)})

      depth == 0 and block_opener?(ctx, at) ->
        frame = {flush(ctx, start, at, acc), depth, at}
        resume(rest, at + 2, ctx, at + 2, {[], [frame | stack], 0, disabled})

      true ->
        single_bracket(bin, at, ctx, start, state)
    end
  end

  defp step(bin, :open_bracket, at, ctx, start, state),
    do: single_bracket(bin, at, ctx, start, state)

  defp step(bin, :close_bracket, at, ctx, start, {acc, stack, depth, disabled}) when depth > 0,
    do: resume(bin, at + 1, ctx, start, {acc, stack, depth - 1, disabled})

  defp step(
         <<?], rest::binary>>,
         :close_bracket,
         at,
         ctx,
         start,
         {acc, [frame | stack], 0, disabled}
       ) do
    {parent, parent_depth, _offset} = frame
    inner = ctx |> flush(start, at, acc) |> Enum.reverse()
    resume(rest, at + 2, ctx, at + 2, {[{:block, inner} | parent], stack, parent_depth, disabled})
  end

  defp step(bin, :close_bracket, at, ctx, start, state),
    do: resume(bin, at + 1, ctx, start, state)

  defp single_bracket(<<_::binary>> = bin, at, ctx(brackets: true) = ctx, start, state),
    do: bracket_identifier(bin, at + 1, ctx, {:identifier, at, start, state})

  defp single_bracket(bin, at, ctx, start, {acc, stack, depth, disabled}),
    do: resume(bin, at + 1, ctx, start, {acc, stack, depth + 1, disabled})

  # ---------------------------------------------------------------------------
  # Placeholders: `{{` is at `at`, the name starts at `pos`. Anything but a
  # valid name and `}}` resumes the code scan after the `{{`.
  # ---------------------------------------------------------------------------

  defp name_start(<<byte, rest::binary>>, pos, ctx, at, start, state) when is_name_start(byte),
    do: name_rest(rest, pos + 1, ctx, at, start, state)

  defp name_start(_bin, _pos, ctx, at, start, state), do: scan(ctx, at + 2, start, state)

  defp name_rest(<<"}}", rest::binary>>, pos, ctx(text: text) = ctx, at, start, state) do
    name = :binary.copy(binary_part(text, at + 2, pos - at - 2))
    token = {:variable, name, binary_part(text, at, pos + 2 - at)}
    push(rest, token, at, pos + 2, ctx, start, state)
  end

  defp name_rest(<<byte, rest::binary>>, pos, ctx, at, start, state) when is_name_byte(byte),
    do: name_rest(rest, pos + 1, ctx, at, start, state)

  defp name_rest(_bin, _pos, ctx, at, start, state), do: scan(ctx, at + 2, start, state)

  # ---------------------------------------------------------------------------
  # Region loops. Each takes the binary after the opening delimiter and its
  # offset, and ends the region after the closing delimiter, or at the end
  # of the input when there is none.
  # ---------------------------------------------------------------------------

  defp quoted(<<byte, byte, rest::binary>>, pos, byte, escapes?, ctx, frame),
    do: quoted(rest, pos + 2, byte, escapes?, ctx, frame)

  defp quoted(<<byte, rest::binary>>, pos, byte, _escapes?, ctx, frame),
    do: close(rest, pos + 1, ctx, frame)

  defp quoted(<<?\\, _, rest::binary>>, pos, quote, true, ctx, frame),
    do: quoted(rest, pos + 2, quote, true, ctx, frame)

  defp quoted(<<_, rest::binary>>, pos, quote, escapes?, ctx, frame),
    do: quoted(rest, pos + 1, quote, escapes?, ctx, frame)

  defp quoted(<<>>, pos, _quote, _escapes?, ctx, frame), do: close(<<>>, pos, ctx, frame)

  # A quote of more than one byte, from a hand-built profile.
  defp quoted_wide(
         <<_::binary>> = bin,
         pos,
         quote,
         escapes?,
         ctx(text: text, size: size) = ctx,
         frame
       ) do
    pattern = if escapes?, do: [quote, "\\"], else: quote
    quote_size = byte_size(quote)

    {skip, closed?} =
      case :binary.match(text, pattern, scope: {pos, size - pos}) do
        :nomatch ->
          {size - pos, true}

        {found, 1} when escapes? ->
          {min(found + 2, size) - pos, false}

        {found, _len} ->
          stop = found + quote_size

          if stop + quote_size <= size and binary_part(text, stop, quote_size) == quote,
            do: {stop + quote_size - pos, false},
            else: {stop - pos, true}
      end

    <<_::binary-size(^skip), rest::binary>> = bin

    if closed?,
      do: close(rest, pos + skip, ctx, frame),
      else: quoted_wide(rest, pos + skip, quote, escapes?, ctx, frame)
  end

  defp bracket_identifier(<<?], rest::binary>>, pos, ctx, frame),
    do: close(rest, pos + 1, ctx, frame)

  defp bracket_identifier(<<_, rest::binary>>, pos, ctx, frame),
    do: bracket_identifier(rest, pos + 1, ctx, frame)

  defp bracket_identifier(<<>>, pos, ctx, frame), do: close(<<>>, pos, ctx, frame)

  defp line(<<?\n, _::binary>> = bin, pos, _cr?, ctx, frame), do: close(bin, pos, ctx, frame)
  defp line(<<?\r, _::binary>> = bin, pos, true, ctx, frame), do: close(bin, pos, ctx, frame)
  defp line(<<_, rest::binary>>, pos, cr?, ctx, frame), do: line(rest, pos + 1, cr?, ctx, frame)
  defp line(<<>>, pos, _cr?, ctx, frame), do: close(<<>>, pos, ctx, frame)

  defp block_comment(<<"*/", rest::binary>>, pos, ctx, frame),
    do: close(rest, pos + 2, ctx, frame)

  defp block_comment(<<_, rest::binary>>, pos, ctx, frame),
    do: block_comment(rest, pos + 1, ctx, frame)

  defp block_comment(<<>>, pos, ctx, frame), do: close(<<>>, pos, ctx, frame)

  defp nested_comment(<<"*/", rest::binary>>, pos, 1, ctx, frame),
    do: close(rest, pos + 2, ctx, frame)

  defp nested_comment(<<"*/", rest::binary>>, pos, depth, ctx, frame),
    do: nested_comment(rest, pos + 2, depth - 1, ctx, frame)

  defp nested_comment(<<"/*", rest::binary>>, pos, depth, ctx, frame),
    do: nested_comment(rest, pos + 2, depth + 1, ctx, frame)

  defp nested_comment(<<_, rest::binary>>, pos, depth, ctx, frame),
    do: nested_comment(rest, pos + 1, depth, ctx, frame)

  defp nested_comment(<<>>, pos, _depth, ctx, frame), do: close(<<>>, pos, ctx, frame)

  # The tag of `$tag$` or `$$` starts at `pos`; a byte that cannot be part
  # of a tag makes the `$` plain code.
  defp dollar_tag(<<?$, rest::binary>>, pos, ctx(text: text) = ctx, frame) do
    {_kind, at, _start, _state} = frame
    # The closing delimiter after its first `$`.
    tail = binary_part(text, at + 1, pos - at)
    dollar_body(rest, pos + 1, tail, ctx, frame)
  end

  defp dollar_tag(<<byte, rest::binary>>, pos, ctx, {_kind, at, _start, _state} = frame)
       when is_tag_start(byte) or (byte in ?0..?9 and pos > at + 1),
       do: dollar_tag(rest, pos + 1, ctx, frame)

  defp dollar_tag(_bin, _pos, ctx, {_kind, at, start, state}), do: scan(ctx, at + 1, start, state)

  # The body starts at `pos`; it ends after the first `$` followed by
  # `tail`, the rest of the opening delimiter.
  defp dollar_body(<<?$, rest::binary>>, pos, tail, ctx, frame) do
    size = byte_size(tail)

    case rest do
      <<^tail::binary-size(^size), rest::binary>> -> close(rest, pos + 1 + size, ctx, frame)
      _ -> dollar_body(rest, pos + 1, tail, ctx, frame)
    end
  end

  defp dollar_body(<<_, rest::binary>>, pos, tail, ctx, frame),
    do: dollar_body(rest, pos + 1, tail, ctx, frame)

  defp dollar_body(<<>>, pos, _tail, ctx, frame), do: close(<<>>, pos, ctx, frame)

  # ---------------------------------------------------------------------------
  # Context checks
  # ---------------------------------------------------------------------------

  defp byte_at(ctx(text: text, size: size), pos) when pos >= 0 and pos < size,
    do: :binary.at(text, pos)

  defp byte_at(_ctx, _pos), do: nil

  defp ident_byte?(byte) when is_integer(byte) and is_ident_byte(byte), do: true
  defp ident_byte?(_byte), do: false

  # The `'` at `at` directly follows a standalone `E` or `e`.
  defp escape_prefixed?(ctx, at) do
    byte_at(ctx, at - 1) in [?E, ?e] and not ident_byte?(byte_at(ctx, at - 2))
  end

  defp block_opener?(ctx, at) do
    not ident_byte?(byte_at(ctx, at - 1)) and not after_array_keyword?(ctx, at)
  end

  # The keyword `ARRAY`, in any case and as a whole word, then only
  # whitespace before `at`.
  defp after_array_keyword?(ctx(text: text) = ctx, at) do
    word_end = skip_whitespace_back(text, at)

    word_end >= 5 and array_word?(binary_part(text, word_end - 5, 5)) and
      not ident_byte?(byte_at(ctx, word_end - 6))
  end

  defp array_word?(<<a, r1, r2, a2, y>>) do
    Bitwise.bor(a, 32) == ?a and Bitwise.bor(r1, 32) == ?r and Bitwise.bor(r2, 32) == ?r and
      Bitwise.bor(a2, 32) == ?a and Bitwise.bor(y, 32) == ?y
  end

  defp skip_whitespace_back(text, pos) when pos > 0 do
    if :binary.at(text, pos - 1) in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v],
      do: skip_whitespace_back(text, pos - 1),
      else: pos
  end

  defp skip_whitespace_back(_text, pos), do: pos
end
