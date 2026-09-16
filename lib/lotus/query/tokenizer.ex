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
  `to_string/1` does that. An unterminated string, comment or dollar quote
  runs to the end of the input. An unclosed `[[` is plain code.

  Placeholders and blocks inside a string, identifier or comment are not
  recognized. String tokens keep their raw text, so a transform that wants
  to see `'{{x}}'` or `'%{{x}}%'` can still inspect the literal.
  """

  alias Lotus.Query.Tokenizer.Profile

  @type token ::
          {:code, String.t()}
          | {:comment, String.t()}
          | {:string, String.t()}
          | {:identifier, String.t()}
          | {:variable, String.t(), String.t()}
          | {:block, [token()]}

  @doc """
  Tokenizes `text` under the lexical rules of `profile`.
  """
  @spec tokenize(String.t(), Profile.t()) :: [token()]
  def tokenize(text, %Profile{} = profile) when is_binary(text) do
    scan(text, profile, [], [], [])
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

  @variable_regex ~r/\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}/

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
        {:string, Regex.replace(@variable_regex, raw, fn _match, name -> fun.(name) end)}

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

    if String.contains?(raw, placeholder) do
      replaced = String.replace(raw, placeholder, replacement, global: false)
      {:ok, Enum.reverse(acc, [{:string, replaced} | rest])}
    else
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

  defp string_variables(raw) do
    @variable_regex
    |> Regex.scan(raw, capture: :all_but_first)
    |> List.flatten()
  end

  # ---------------------------------------------------------------------------
  # Scanner
  #
  # `tokens` and `code` are reversed accumulators. `stack` holds the parent
  # accumulators of every open `[[` block.
  # ---------------------------------------------------------------------------

  defp scan(<<>>, _profile, tokens, code, []) do
    tokens |> flush_code(code) |> Enum.reverse()
  end

  defp scan(<<>>, profile, tokens, code, [{parent_tokens, parent_code} | stack]) do
    inner = tokens |> flush_code(code) |> Enum.reverse()
    {tokens, code} = reopen_as_code(parent_tokens, ["[[" | parent_code], inner)
    scan(<<>>, profile, tokens, code, stack)
  end

  defp scan(<<"{{", rest::binary>> = input, profile, tokens, code, stack) do
    case take_variable(rest) do
      {:ok, name, after_var} ->
        raw = binary_part(input, 0, byte_size(input) - byte_size(after_var))
        tokens = [{:variable, name, raw} | flush_code(tokens, code)]
        scan(after_var, profile, tokens, [], stack)

      :error ->
        scan(rest, profile, tokens, ["{{" | code], stack)
    end
  end

  defp scan(<<"[[", rest::binary>>, profile, tokens, code, stack) do
    scan(rest, profile, [], [], [{tokens, code} | stack])
  end

  defp scan(<<"]]", rest::binary>>, profile, tokens, code, [{parent_tokens, parent_code} | stack]) do
    inner = tokens |> flush_code(code) |> Enum.reverse()
    tokens = [{:block, inner} | flush_code(parent_tokens, parent_code)]
    scan(rest, profile, tokens, [], stack)
  end

  defp scan(input, profile, tokens, code, stack) do
    case region(input, profile) do
      {kind, raw, rest} ->
        scan(rest, profile, [{kind, raw} | flush_code(tokens, code)], [], stack)

      nil ->
        {char, rest} = take_char(input)
        scan(rest, profile, tokens, [char | code], stack)
    end
  end

  defp flush_code(tokens, []), do: tokens

  defp flush_code(tokens, code) do
    [{:code, code |> Enum.reverse() |> IO.iodata_to_binary()} | tokens]
  end

  defp reopen_as_code(tokens, code, inner) do
    Enum.reduce(inner, {tokens, code}, fn
      {:code, raw}, {tokens, code} -> {tokens, [raw | code]}
      token, {tokens, code} -> {[token | flush_code(tokens, code)], []}
    end)
  end

  defp take_char(<<char::utf8, rest::binary>>), do: {<<char::utf8>>, rest}
  defp take_char(<<byte, rest::binary>>), do: {<<byte>>, rest}

  # ---------------------------------------------------------------------------
  # Variables
  # ---------------------------------------------------------------------------

  defp take_variable(<<first, rest::binary>>)
       when first in ?A..?Z or first in ?a..?z or first == ?_ do
    take_variable_name(rest, <<first>>)
  end

  defp take_variable(_), do: :error

  defp take_variable_name(<<"}}", rest::binary>>, name), do: {:ok, name, rest}

  defp take_variable_name(<<char, rest::binary>>, name)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ do
    take_variable_name(rest, <<name::binary, char>>)
  end

  defp take_variable_name(_, _), do: :error

  # ---------------------------------------------------------------------------
  # Non-code regions
  # ---------------------------------------------------------------------------

  defp region(input, profile) do
    line_comment(input, profile) ||
      block_comment(input, profile) ||
      quoted(input, profile.string_quotes, :string, profile.backslash_escapes?) ||
      quoted(input, profile.identifier_quotes, :identifier, false) ||
      dollar_quoted(input, profile)
  end

  defp line_comment(input, %Profile{line_comments: markers}) do
    case take_prefix(input, markers) do
      {marker, rest} ->
        {body, rest} = take_until(rest, "\n")
        {:comment, marker <> body, rest}

      nil ->
        nil
    end
  end

  defp block_comment(<<"/*", rest::binary>>, %Profile{block_comments?: true} = profile) do
    {body, rest} = take_block_comment(rest, 1, profile.nested_block_comments?, [])
    {:comment, "/*" <> body, rest}
  end

  defp block_comment(_input, _profile), do: nil

  defp take_block_comment(<<>>, _depth, _nested?, acc), do: {finish(acc), <<>>}

  defp take_block_comment(<<"*/", rest::binary>>, 1, _nested?, acc) do
    {finish(["*/" | acc]), rest}
  end

  defp take_block_comment(<<"*/", rest::binary>>, depth, true, acc) do
    take_block_comment(rest, depth - 1, true, ["*/" | acc])
  end

  defp take_block_comment(<<"/*", rest::binary>>, depth, true, acc) do
    take_block_comment(rest, depth + 1, true, ["/*" | acc])
  end

  defp take_block_comment(input, depth, nested?, acc) do
    {char, rest} = take_char(input)
    take_block_comment(rest, depth, nested?, [char | acc])
  end

  defp quoted(input, quotes, kind, escapes?) do
    case take_prefix(input, quotes) do
      {quote, rest} ->
        {body, rest} = take_quoted(rest, quote, escapes?, [])
        {kind, quote <> body, rest}

      nil ->
        nil
    end
  end

  defp take_quoted(<<>>, _quote, _escapes?, acc), do: {finish(acc), <<>>}

  defp take_quoted(<<"\\">>, _quote, true, acc), do: {finish(["\\" | acc]), <<>>}

  defp take_quoted(<<"\\", rest::binary>>, quote, true, acc) do
    {char, rest} = take_char(rest)
    take_quoted(rest, quote, true, [char, "\\" | acc])
  end

  defp take_quoted(input, quote, escapes?, acc) do
    doubled = quote <> quote

    cond do
      String.starts_with?(input, doubled) ->
        take_quoted(drop(input, doubled), quote, escapes?, [doubled | acc])

      String.starts_with?(input, quote) ->
        {finish([quote | acc]), drop(input, quote)}

      true ->
        {char, rest} = take_char(input)
        take_quoted(rest, quote, escapes?, [char | acc])
    end
  end

  defp dollar_quoted(<<"$", rest::binary>>, %Profile{dollar_quotes?: true}) do
    case take_dollar_tag(rest) do
      {:ok, tag, rest} ->
        closer = "$" <> tag <> "$"

        case :binary.match(rest, closer) do
          {pos, len} ->
            body = binary_part(rest, 0, pos + len)
            {:string, closer <> body, binary_part(rest, pos + len, byte_size(rest) - pos - len)}

          :nomatch ->
            {:string, closer <> rest, <<>>}
        end

      :error ->
        nil
    end
  end

  defp dollar_quoted(_input, _profile), do: nil

  defp take_dollar_tag(<<"$", rest::binary>>), do: {:ok, "", rest}

  defp take_dollar_tag(<<first, rest::binary>>)
       when first in ?A..?Z or first in ?a..?z or first == ?_ do
    take_dollar_tag(rest, <<first>>)
  end

  defp take_dollar_tag(_), do: :error

  defp take_dollar_tag(<<"$", rest::binary>>, tag), do: {:ok, tag, rest}

  defp take_dollar_tag(<<char, rest::binary>>, tag)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ do
    take_dollar_tag(rest, <<tag::binary, char>>)
  end

  defp take_dollar_tag(_, _), do: :error

  # ---------------------------------------------------------------------------
  # Binary helpers
  # ---------------------------------------------------------------------------

  defp take_prefix(input, markers) do
    Enum.find_value(markers, fn marker ->
      if String.starts_with?(input, marker), do: {marker, drop(input, marker)}
    end)
  end

  defp take_until(input, stop) do
    case :binary.match(input, stop) do
      {pos, _len} -> {binary_part(input, 0, pos), binary_part(input, pos, byte_size(input) - pos)}
      :nomatch -> {input, <<>>}
    end
  end

  defp drop(input, prefix) do
    size = byte_size(prefix)
    binary_part(input, size, byte_size(input) - size)
  end

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
