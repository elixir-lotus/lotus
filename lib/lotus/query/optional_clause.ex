defmodule Lotus.Query.OptionalClause do
  @moduledoc """
  Processes `[[...]]` optional clause syntax in any text-based query language.

  Clauses wrapped in double brackets are stripped entirely when the enclosed
  variables have no value, making them optional. When all variables inside a
  block have values, the brackets are removed and the content is kept.

  The `[[ ... ]]` / `{{var}}` template syntax is language-agnostic — it works
  on SQL, JSON DSLs, Cypher, or any other textual query format. Adapters that
  work on AST representations should apply this before serialization.

  Blocks are found with `Lotus.Query.Tokenizer`, so `[[` inside a string
  literal or a comment is plain text, and a `{{var}}` inside a comment does
  not make a block conditional. Blocks nest: an inner block is resolved on
  its own, and the outer block only depends on the variables directly inside
  it. Every function takes an optional `Lotus.Query.Tokenizer.Profile`; the
  default is ANSI SQL.

  ## Example (SQL)

      SELECT * FROM users
      WHERE 1=1
        [[AND "name" ILIKE '%' || {{name}} || '%']]
        [[AND "status" = {{status}}]]

  If `name` has no value, the first `[[...]]` block is removed entirely.
  If `status` has a value, the second block becomes `AND "status" = {{status}}`.
  """

  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile

  @doc """
  Processes optional clauses in SQL. Removes `[[...]]` blocks where any
  enclosed variable has no value. Keeps content (without brackets) when
  all variables have values.

  A variable is considered to have "no value" when it is missing from
  `supplied_vars`, is `nil`, or is `""`.
  """
  @spec process(String.t(), map(), Profile.t()) :: String.t()
  def process(sql, supplied_vars, %Profile{} = profile \\ Profile.for_language("sql")) do
    sql
    |> Tokenizer.tokenize(profile)
    |> process_tokens(supplied_vars)
    |> IO.iodata_to_binary()
  end

  defp process_tokens(tokens, supplied_vars) do
    Enum.map(tokens, fn
      {:block, inner} ->
        if Enum.all?(direct_variables(inner), &has_value?(supplied_vars, &1)) do
          process_tokens(inner, supplied_vars)
        else
          ""
        end

      token ->
        Tokenizer.to_iodata([token])
    end)
  end

  defp direct_variables(tokens) do
    tokens
    |> Enum.reject(&match?({:block, _}, &1))
    |> Tokenizer.variables()
    |> Enum.uniq()
  end

  @doc """
  Returns a `MapSet` of variable names that appear inside `[[...]]` blocks.
  """
  @spec extract_optional_variable_names(String.t(), Profile.t()) :: MapSet.t()
  def extract_optional_variable_names(sql, %Profile{} = profile \\ Profile.for_language("sql")) do
    sql
    |> Tokenizer.tokenize(profile)
    |> block_variables()
    |> MapSet.new()
  end

  defp block_variables(tokens) do
    Enum.flat_map(tokens, fn
      {:block, inner} -> Tokenizer.variables(inner)
      _token -> []
    end)
  end

  @doc """
  Strips `[[` and `]]` brackets from the string, keeping the inner content.

  Unlike `process/2`, this does not evaluate variables — it unconditionally
  removes all bracket pairs. Useful for preparing SQL for validation where
  all optional clauses should be included.

  ## Examples

      iex> Lotus.Query.OptionalClause.strip_brackets("WHERE 1=1 [[AND status = 'active']]")
      "WHERE 1=1 AND status = 'active'"
  """
  @spec strip_brackets(String.t(), Profile.t()) :: String.t()
  def strip_brackets(content, %Profile{} = profile \\ Profile.for_language("sql")) do
    content
    |> Tokenizer.tokenize(profile)
    |> unwrap_blocks()
    |> IO.iodata_to_binary()
  end

  defp unwrap_blocks(tokens) do
    Enum.map(tokens, fn
      {:block, inner} -> unwrap_blocks(inner)
      token -> Tokenizer.to_iodata([token])
    end)
  end

  defp has_value?(supplied_vars, name) do
    case Map.get(supplied_vars, name) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
