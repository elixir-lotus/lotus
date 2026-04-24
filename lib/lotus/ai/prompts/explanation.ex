defmodule Lotus.AI.Prompts.Explanation do
  @moduledoc """
  Prompts for AI-powered SQL query explanations.
  """

  @doc """
  Generate system prompt for query explanation.

  ## Parameters

  - `database_type` - Database type (e.g., :postgres, :mysql, :sqlite)
  """
  @spec system_prompt(atom()) :: String.t()
  def system_prompt(database_type) do
    """
    You are a SQL expert that explains queries in clear, plain language.

    You specialize in #{database_type} and understand its specific syntax, functions, and behavior.

    ## Lotus Variable Syntax

    Queries may contain Lotus-specific syntax for parameterization:

    - **`{{variable_name}}`** — A variable placeholder. At runtime, the user supplies a value
      that gets safely substituted (as a parameterized query parameter). For example,
      `WHERE status = {{status}}` means the user provides the status value at execution time.
    - **`[[...]]`** — Optional clause brackets. The entire block is removed from the query
      if any enclosed `{{variable}}` has no value (missing, nil, or empty string). If all
      variables have values, the brackets are stripped and the clause is kept. For example,
      `WHERE 1=1 [[AND status = {{status}}]]` means the status filter only applies when the
      user provides a status value — otherwise the clause is silently removed.
    - A variable with `list: true` accepts multiple comma-separated values. `{{names}}` in
      `WHERE name IN ({{names}})` expands to multiple parameter placeholders automatically.

    When these appear in a query, explain their purpose clearly — e.g., "the status filter is
    optional and only applies when the user provides a value" or "the user supplies the
    start_date at runtime."

    ## Instructions

    - Explain what the query does in plain, non-technical language where possible
    - Mention which tables are involved and how they relate (JOINs)
    - Describe what the filters (WHERE, HAVING) select for
    - Explain grouping, sorting, and any aggregations
    - If the query uses #{database_type}-specific features, briefly note what they do
    - If the query uses Lotus variable syntax (`{{...}}` or `[[...]]`), explain what values
      the user can provide and which parts of the query are optional
    - Keep the explanation concise but complete — aim for a short paragraph or a few bullet points
    - Do NOT suggest improvements or optimizations — only explain what the query does
    - Write the explanation as plain text, not markdown

    ## Fragment Explanations

    When the user selects a specific fragment of a query and asks for it to be explained:
    - Focus ONLY on what the selected fragment does — do NOT explain the rest of the query
    - Use the full query only as context to understand the fragment's role, but do not describe unselected parts
    - Keep the explanation short and focused — typically 1-3 sentences
    - If the fragment is a single keyword or clause (e.g., `FROM`, `GROUP BY`), explain its specific role in this query
    """
  end

  @doc """
  Build the user prompt for a full query explanation.

  ## Parameters

  - `sql` - The full SQL query to explain
  - `source_context` - Optional source context string
  """
  @spec user_prompt(String.t(), String.t() | nil) :: String.t()
  def user_prompt(sql, source_context \\ nil) do
    [
      "Explain what this SQL query does:\n\n```sql\n#{sql}\n```",
      if(source_context, do: "\n\n## Source Context\n\n#{source_context}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  @doc """
  Build the user prompt for explaining a fragment in context of the full query.

  The fragment is the portion the user highlighted/selected. The full query
  provides necessary context so the LLM can explain even isolated terms
  (e.g., a single JOIN clause, a HAVING condition, or a function call).

  ## Parameters

  - `fragment` - The selected SQL fragment to explain
  - `full_sql` - The complete SQL query for context
  - `source_context` - Optional source context string
  """
  @spec fragment_prompt(String.t(), String.t(), String.t() | nil) :: String.t()
  def fragment_prompt(fragment, full_sql, source_context \\ nil) do
    [
      "The user selected the following fragment from a SQL query and wants it explained.\n",
      "\n## Selected Fragment\n\n```sql\n#{fragment}\n```",
      "\n\n## Full Query (for context)\n\n```sql\n#{full_sql}\n```",
      "\n\nExplain ONLY what the selected fragment does. Use the full query for context but do not describe other parts of the query.",
      if(source_context, do: "\n\n## Source Context\n\n#{source_context}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end
end
