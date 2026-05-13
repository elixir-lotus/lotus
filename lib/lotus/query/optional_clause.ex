defmodule Lotus.Query.OptionalClause do
  @moduledoc """
  Processes `[[...]]` optional clause syntax in any text-based query language.

  Clauses wrapped in double brackets are stripped entirely when the enclosed
  variables have no value, making them optional. When all variables inside a
  block have values, the brackets are removed and the content is kept.

  The `[[ ... ]]` / `{{var}}` template syntax is language-agnostic — it works
  on SQL, JSON DSLs, Cypher, or any other textual query format. Adapters that
  work on AST representations should apply this before serialization.

  ## Example (SQL)

      SELECT * FROM users
      WHERE 1=1
        [[AND "name" ILIKE '%' || {{name}} || '%']]
        [[AND "status" = {{status}}]]

  If `name` has no value, the first `[[...]]` block is removed entirely.
  If `status` has a value, the second block becomes `AND "status" = {{status}}`.
  """

  @optional_clause_regex ~r/\[\[(.*?)\]\]/s

  @doc """
  Processes optional clauses in SQL. Removes `[[...]]` blocks where any
  enclosed variable has no value. Keeps content (without brackets) when
  all variables have values.

  A variable is considered to have "no value" when it is missing from
  `supplied_vars`, is `nil`, or is `""`.
  """
  @spec process(String.t(), map()) :: String.t()
  def process(sql, supplied_vars) do
    Regex.replace(@optional_clause_regex, sql, fn _full, content ->
      vars_in_block =
        content
        |> Lotus.Variables.extract_names()
        |> Enum.uniq()

      if Enum.all?(vars_in_block, &has_value?(supplied_vars, &1)) do
        content
      else
        ""
      end
    end)
  end

  @doc """
  Returns a `MapSet` of variable names that appear inside `[[...]]` blocks.
  """
  @spec extract_optional_variable_names(String.t()) :: MapSet.t()
  def extract_optional_variable_names(sql) do
    Regex.scan(@optional_clause_regex, sql)
    |> Enum.flat_map(fn [_, content] ->
      Lotus.Variables.extract_names(content)
    end)
    |> MapSet.new()
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
  @spec strip_brackets(String.t()) :: String.t()
  def strip_brackets(content) do
    Regex.replace(@optional_clause_regex, content, "\\1")
  end

  defp has_value?(supplied_vars, name) do
    case Map.get(supplied_vars, name) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
