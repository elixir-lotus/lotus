defmodule Lotus.AI.Prompts.Optimization do
  @moduledoc """
  System prompts for AI-powered query optimization suggestions.

  Prompts are layered the same way as `Lotus.AI.Prompts.QueryGeneration`:
  core review rules (language-agnostic) precede adapter-supplied syntax
  notes, so a compromised adapter cannot repeal them via later text.
  """

  @doc """
  Generate system prompt for query optimization analysis.

  ## Composition order

    1. System role, keyed off `ai_context.language` (core)
    2. Response contract (core)
    3. Core optimization heuristics — language-agnostic (core)
    4. Adapter `syntax_notes` — filtered if untrusted (adapter)
    5. Rules / response-format example (core)

  ## Parameters

    * `ai_context` — the adapter's `ai_context_map` (`:language`,
      `:syntax_notes`, ...).
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(ai_context) do
    language = Map.get(ai_context, :language, "sql")
    syntax_notes = Map.get(ai_context, :syntax_notes, "")

    """
    You are a database performance expert specializing in "#{language}" query optimization.

    You will receive a statement and (when available) its execution plan or diagnostic.
    Analyze them and provide actionable optimization suggestions. When no execution plan
    is supplied, review the statement structurally and suggest improvements from patterns
    visible in the query itself.

    ## Response Format

    Respond with a JSON array of suggestion objects. Each suggestion must have:
    - `"type"` — one of: `"index"`, `"rewrite"`, `"structure"`, `"configuration"`
    - `"impact"` — one of: `"high"`, `"medium"`, `"low"`
    - `"title"` — short summary (under 100 characters)
    - `"suggestion"` — detailed explanation of what to change and why

    #{core_optimization_notes()}

    ## Language-Specific Notes (from adapter):
    #{syntax_notes}

    ## Rules

    - Only suggest improvements that are clearly supported by the execution plan or query structure
    - Be specific: name the exact columns, tables, and index definitions
    - For index suggestions, provide the exact CREATE INDEX statement
    - For query rewrites, provide the rewritten SQL
    - Do not suggest changes that would alter query semantics
    - If the query is already well-optimized, return an empty array `[]`
    - Return ONLY the JSON array, no other text

    ## Example Response

    ```json
    [
      {
        "type": "index",
        "impact": "high",
        "title": "Add index on orders.created_at",
        "suggestion": "The query performs a sequential scan on the orders table filtered by created_at. Adding an index would allow an index scan instead.\\n\\nCREATE INDEX idx_orders_created_at ON orders (created_at);"
      },
      {
        "type": "rewrite",
        "impact": "medium",
        "title": "Replace subquery with JOIN",
        "suggestion": "The correlated subquery in the WHERE clause executes once per row. Rewriting as a JOIN is more efficient.\\n\\nSELECT o.* FROM orders o JOIN customers c ON o.customer_id = c.id WHERE c.active = true;"
      }
    ]
    ```
    """
  end

  @doc """
  Build the user prompt containing the SQL and execution plan.

  ## Parameters

  - `sql` - The SQL query to optimize
  - `execution_plan` - The execution plan string (from EXPLAIN)
  - `source_context` - Optional source context string
  """
  @spec user_prompt(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def user_prompt(sql, execution_plan, source_context \\ nil) do
    [
      "## SQL Query\n\n```sql\n#{sql}\n```",
      if(execution_plan, do: "\n\n## Execution Plan\n\n```\n#{execution_plan}\n```"),
      if(source_context, do: "\n\n## Source Context\n\n#{source_context}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  @doc """
  Parse the AI response into a list of suggestion maps.

  Returns a list of validated suggestion maps or an empty list if parsing fails.
  """
  @spec parse_suggestions(String.t()) :: [map()]
  def parse_suggestions(content) do
    content
    |> extract_json()
    |> parse_json()
    |> validate_suggestions()
  end

  defp extract_json(content) do
    case Regex.run(~r/```(?:json)?\s*\n(.*?)\n```/s, content) do
      [_, json] -> String.trim(json)
      nil -> String.trim(content)
    end
  end

  defp parse_json(json_str) do
    case Lotus.JSON.decode(json_str) do
      {:ok, suggestions} when is_list(suggestions) -> suggestions
      _ -> []
    end
  end

  @valid_types ~w(index rewrite structure configuration)
  @valid_impacts ~w(high medium low)

  defp validate_suggestions(suggestions) do
    suggestions
    |> Enum.filter(&valid_suggestion?/1)
    |> Enum.map(&normalize_suggestion/1)
  end

  defp valid_suggestion?(s) when is_map(s) do
    is_binary(s["type"]) and is_binary(s["suggestion"])
  end

  defp valid_suggestion?(_), do: false

  defp normalize_suggestion(s) do
    %{
      "type" => normalize_type(s["type"]),
      "impact" => normalize_impact(s["impact"]),
      "title" => s["title"] || summarize_suggestion(s["suggestion"]),
      "suggestion" => s["suggestion"]
    }
  end

  defp normalize_type(type) when type in @valid_types, do: type
  defp normalize_type(_), do: "rewrite"

  defp normalize_impact(impact) when impact in @valid_impacts, do: impact
  defp normalize_impact(_), do: "medium"

  defp summarize_suggestion(suggestion) do
    suggestion
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 100)
  end

  # Core, language-agnostic optimization heuristics. Kept in the prompt
  # builder (not an adapter callback) so untrusted adapters can't repeal
  # them. Adapter-specific vocabulary (SQL index types, ES mapping
  # tuning, Mongo index hints) lives in `ai_context.syntax_notes`.
  defp core_optimization_notes do
    """
    ## What to look for (language-agnostic)

    - **Full scans** on large collections that could benefit from an index / filter pushdown
    - **Missing secondary access paths** on columns used to filter, join, order, or group
    - **Unnecessary result set size** — selecting more fields than needed, or missing a LIMIT
    - **Correlated / nested queries** that could be flattened or batched
    - **Type coercion at access time** that prevents index usage (implicit casts, mixed-type compares)
    - **Redundant joins / lookups** that can be dropped without changing results
    - **Inefficient sorting** — external merge / temp sort when an ordered index exists
    - **N+1-ish patterns** — repeated one-row lookups that could be a single pass
    - **Overly broad filters** that the engine can't push down to an access path
    """
  end
end
