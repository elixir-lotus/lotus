defmodule Lotus.Query.Tokenizer.Profile do
  @moduledoc """
  Lexical rules that tell `Lotus.Query.Tokenizer` which regions of a
  statement are not code: string literals, quoted identifiers and comments.

  A profile does not describe a grammar. It only lists the delimiters the
  tokenizer must skip so that `{{var}}` and `[[...]]` template syntax is
  recognized in code and never inside a literal or a comment.

  Built-in profiles are selected by query language with `for_language/1`.
  An adapter that declares a `dialect_spec` in its editor config can refine
  a base profile with `from_dialect_spec/2`, so one declaration drives both
  the editor's highlighter and the server-side tokenizer.
  """

  @type t :: %__MODULE__{
          string_quotes: [String.t()],
          identifier_quotes: [String.t()],
          line_comments: [String.t()],
          block_comments?: boolean(),
          nested_block_comments?: boolean(),
          dollar_quotes?: boolean(),
          backslash_escapes?: boolean()
        }

  defstruct string_quotes: ["'"],
            identifier_quotes: ["\""],
            line_comments: ["--"],
            block_comments?: true,
            nested_block_comments?: false,
            dollar_quotes?: false,
            backslash_escapes?: false

  @doc """
  Returns the built-in profile for a query language identifier such as
  `"sql:postgres"` or `"json:elasticsearch"`.

  Unknown languages, unknown SQL dialects and `nil` get the ANSI SQL
  profile: single-quoted strings, double-quoted identifiers, `--` and
  `/* */` comments.
  """
  @spec for_language(String.t() | nil) :: t()
  def for_language("sql:postgres") do
    %__MODULE__{dollar_quotes?: true, nested_block_comments?: true}
  end

  def for_language("sql:mysql") do
    %__MODULE__{
      string_quotes: ["'", "\""],
      identifier_quotes: ["`"],
      line_comments: ["--", "#"],
      backslash_escapes?: true
    }
  end

  def for_language("sql:sqlite") do
    %__MODULE__{identifier_quotes: ["\"", "`"]}
  end

  def for_language(language) when is_binary(language) do
    case language_family(language) do
      "json" ->
        %__MODULE__{
          string_quotes: ["\""],
          identifier_quotes: [],
          line_comments: [],
          block_comments?: false,
          backslash_escapes?: true
        }

      _ ->
        %__MODULE__{}
    end
  end

  def for_language(nil), do: %__MODULE__{}

  defp language_family(language) do
    language |> String.split(":", parts: 2) |> hd()
  end

  @doc """
  Refines `base` with the lexical keys of an adapter's `dialect_spec`.

  Recognized keys mirror `t:Lotus.Source.Adapter.dialect_spec/0`:
  `:identifier_quotes`, `:hash_comments`, `:slash_comments`,
  `:double_quoted_strings`, `:double_dollar_quoted_strings` and
  `:backslash_escapes`. Other keys are ignored. A `nil` spec returns
  `base` unchanged.
  """
  @spec from_dialect_spec(t(), map() | nil) :: t()
  def from_dialect_spec(%__MODULE__{} = base, nil), do: base

  def from_dialect_spec(%__MODULE__{} = base, spec) when is_map(spec) do
    base
    |> apply_identifier_quotes(spec)
    |> apply_line_comment(spec, :hash_comments, "#")
    |> apply_line_comment(spec, :slash_comments, "//")
    |> apply_double_quoted_strings(spec)
    |> apply_flag(spec, :double_dollar_quoted_strings, :dollar_quotes?)
    |> apply_flag(spec, :backslash_escapes, :backslash_escapes?)
  end

  defp apply_identifier_quotes(profile, %{identifier_quotes: quotes}) when is_binary(quotes) do
    %{profile | identifier_quotes: String.graphemes(quotes)}
  end

  defp apply_identifier_quotes(profile, _spec), do: profile

  defp apply_line_comment(profile, spec, key, marker) do
    case Map.get(spec, key) do
      true -> %{profile | line_comments: Enum.uniq(profile.line_comments ++ [marker])}
      false -> %{profile | line_comments: List.delete(profile.line_comments, marker)}
      _ -> profile
    end
  end

  defp apply_double_quoted_strings(profile, %{double_quoted_strings: true}) do
    %{
      profile
      | string_quotes: Enum.uniq(profile.string_quotes ++ ["\""]),
        identifier_quotes: List.delete(profile.identifier_quotes, "\"")
    }
  end

  defp apply_double_quoted_strings(profile, %{double_quoted_strings: false}) do
    %{profile | string_quotes: List.delete(profile.string_quotes, "\"")}
  end

  defp apply_double_quoted_strings(profile, _spec), do: profile

  defp apply_flag(profile, spec, key, field) do
    case Map.get(spec, key) do
      value when is_boolean(value) -> Map.put(profile, field, value)
      _ -> profile
    end
  end
end
