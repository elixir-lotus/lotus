defmodule Lotus.Variables do
  @moduledoc """
  Utilities for Lotus `{{variable}}` template syntax.

  Variables use the `{{name}}` placeholder format and can appear in SQL
  queries, templates, or any other Lotus content type.

  Placeholders are found with `Lotus.Query.Tokenizer`, so a `{{name}}`
  inside a comment or a quoted identifier is not a variable. A placeholder
  inside a string literal is, because the dialect transformer rewrites
  literals such as `'%{{q}}%'` before binding. Every function takes an
  optional `Lotus.Query.Tokenizer.Profile`; the default is ANSI SQL.
  """

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile

  @variable_regex ~r/\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}/

  @doc deprecated:
         "The pipeline tokenizes with Lotus.Query.Tokenizer; this regex is kept for callers that match raw text."
  @doc """
  Returns the compiled regex for matching `{{variable}}` placeholders.

  Captures the variable name (without braces) in group 1. The regex is not
  aware of comments or literals; prefer `extract_names/2`.

  ## Examples

      iex> Regex.scan(Lotus.Variables.regex(), "WHERE id = {{user_id}}")
      [["{{user_id}}", "user_id"]]
  """
  @spec regex() :: Regex.t()
  def regex, do: @variable_regex

  @doc """
  Extracts variable names from a string containing `{{variable}}` placeholders.

  Returns names in the order they appear, with duplicates preserved.

  ## Examples

      iex> Lotus.Variables.extract_names("WHERE id = {{user_id}} AND status = {{status}}")
      ["user_id", "status"]

      iex> Lotus.Variables.extract_names("no variables here")
      []

      iex> Lotus.Variables.extract_names("-- {{note}}\\nSELECT {{id}}")
      ["id"]
  """
  @spec extract_names(String.t(), Profile.t()) :: [String.t()]
  def extract_names(content, %Profile{} = profile \\ Profile.for_language("sql")) do
    content |> Tokenizer.tokenize(profile) |> Tokenizer.variables()
  end

  @doc """
  Replaces all `{{variable}}` placeholders with the given replacement value.

  Useful for neutralizing variables before validation (e.g. replacing with
  `"NULL"` for SQL syntax checking) or for any context where placeholders
  need to be substituted with a static value.

  ## Examples

      iex> Lotus.Variables.neutralize("SELECT * FROM users WHERE id = {{user_id}}", "NULL")
      "SELECT * FROM users WHERE id = NULL"

      iex> Lotus.Variables.neutralize("Hello {{name}}", "")
      "Hello "
  """
  @spec neutralize(String.t(), String.t(), Profile.t()) :: String.t()
  def neutralize(content, replacement, %Profile{} = profile \\ Profile.for_language("sql")) do
    content
    |> Tokenizer.tokenize(profile)
    |> Tokenizer.replace_variables(fn _name -> replacement end)
    |> Tokenizer.to_string()
  end
end
