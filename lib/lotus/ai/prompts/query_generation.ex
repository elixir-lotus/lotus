defmodule Lotus.AI.Prompts.QueryGeneration do
  @moduledoc """
  System prompts for query generation.

  Prompts are assembled in a fixed order so that **core Lotus rules** (the
  `{{var}}` / `[[...]]` template DSL, the response contract, the workflow
  instructions) always precede **adapter-contributed content** (the
  `ai_context.syntax_notes` and `:example_query`). Untrusted adapters have
  their free-form fields stripped upstream in
  `Lotus.Source.Adapter.ai_context/1`; placing core content first means a
  compromised adapter cannot override the Lotus DSL rules through later
  text.
  """

  alias Lotus.AI.Prompts.Variables

  @doc """
  Generate system prompt for query generation.

  ## Composition order

  Each section is emitted in this order to establish the trust boundary:

    1. System role (core)
    2. Read-only / write-only instructions (core)
    3. Available tables (core, schema context)
    4. Tools + workflow (core)
    5. Lotus template DSL rules (core, immutable — `lotus_template_notes/0` + `Variables.system_docs/0`)
    6. Adapter `syntax_notes` (filtered if untrusted, truncated at 1 KB)
    7. Adapter `example_query` (bounded at 2 KB)
    8. Output contract examples (core)

  ## Parameters

    * `ai_context` — the sanitized map returned by
      `Lotus.Source.Adapter.ai_context/1` (`:language`, `:example_query`,
      `:syntax_notes`, `:error_patterns`).
    * `table_names` — list of available table names.
    * `opts` — keyword list:
      * `:read_only` — when `true` (default), instruct the LLM to stick to
        read-only statements.
  """
  @spec system_prompt(map(), [String.t()], keyword()) :: String.t()
  def system_prompt(ai_context, table_names, opts \\ []) do
    read_only = Keyword.get(opts, :read_only, true)
    language = Map.get(ai_context, :language, "sql")
    syntax_notes = Map.get(ai_context, :syntax_notes, "")
    example = Map.get(ai_context, :example_query, "")

    """
    You are a specialized query generator for the "#{language}" query language.
    #{read_only_instructions(read_only)}

    ## Available Tables:
    #{Enum.join(table_names, ", ")}

    Note: Table names may be schema-qualified (e.g., "public.users", "reporting.customers").
    Always use the full schema-qualified name in your statements when provided.

    ## Tools:
    - `list_schemas()` - Get list of all database schemas
    - `list_tables()` - Get full table list with schema names
    - `describe_table(table_name)` - Get columns for a table (use schema-qualified name if available)
    - `get_column_values(table_name, column_name)` - Get distinct values for a column (e.g., status codes, categories)
    - `validate_sql(sql)` - Check statement syntax against the data source without executing it

    ## Workflow:
    1. Identify relevant tables for the question
    2. Use `describe_table()` for those tables (with schema-qualified names)
    3. **IMPORTANT:** For queries involving specific values (status, type, category), use `get_column_values()` to discover actual values
    4. Validate required data exists
    5. Generate the statement and use `validate_sql()` to verify syntax before returning
    6. If invalid, fix errors and re-validate
    7. If the question cannot be answered, respond UNABLE_TO_GENERATE

    ## Best Practices:
    - When query mentions terms like "outstanding", "active", "pending" - use `get_column_values()` to find actual status values
    - When filtering by categories/types - check actual values first with `get_column_values()`
    - Don't assume enum values - always verify with the tool

    ## Guidelines:
    - Return ONLY the statement in ```sql blocks
    - Use full schema-qualified table names (e.g., SELECT * FROM reporting.customers)
    - Use JOINs for multi-table queries
    - Add LIMIT for safety (unless explicitly asked for all results)
    - Prefer explicit column names over SELECT *

    #{Variables.system_docs()}
    #{lotus_template_notes()}

    ## Language-Specific Notes (from adapter):
    #{syntax_notes}

    ## Example Statement:
    #{example}

    ## Examples:
    - "Active users in last 7 days" → Query users table if it has created_at/status
    - "Top 5 products by sales" → Query if products/orders tables exist
    - "Who is CEO?" → UNABLE_TO_GENERATE: org chart not in database
    - "Send email to customers" → UNABLE_TO_GENERATE: cannot perform actions
    - "What's the weather?" → UNABLE_TO_GENERATE: not a database question
    """
  end

  @doc """
  Extract SQL from LLM response content.

  Handles both markdown-wrapped SQL and plain SQL responses, and detects
  when the LLM has refused to generate SQL.

  ## Parameters

  - `content` - Raw response content from the LLM

  ## Returns

  - `{:ok, sql}` - Successfully extracted SQL query
  - `{:error, {:unable_to_generate, reason}}` - LLM refused to generate

  ## Examples

      iex> extract_sql("```sql\\nSELECT * FROM users\\n```")
      {:ok, "SELECT * FROM users"}

      iex> extract_sql("UNABLE_TO_GENERATE: This is a weather question")
      {:error, {:unable_to_generate, "This is a weather question"}}
  """
  @spec extract_sql(String.t()) :: {:ok, String.t()} | {:error, {:unable_to_generate, String.t()}}
  def extract_sql(content) do
    content = String.trim(content)

    if String.starts_with?(content, "UNABLE_TO_GENERATE:") do
      reason = String.replace_prefix(content, "UNABLE_TO_GENERATE: ", "")
      {:error, {:unable_to_generate, reason}}
    else
      case Regex.run(~r/```sql\s*\n(.*?)\n```/s, content) do
        [_, sql] ->
          {:ok, String.trim(sql)}

        nil ->
          {:error, {:unable_to_generate, content}}
      end
    end
  end

  @doc ~S"""
  Extract variable configurations from LLM response content.

  Parses a ```` ```variables ```` JSON block from the response. Returns an empty list
  if no block is found or if the JSON is malformed.

  ## Parameters

  - `content` - Raw response content from the LLM

  ## Returns

  List of variable configuration maps (empty list if none found).

  ## Examples

      iex> extract_variables("```variables\n[{\"name\": \"status\", \"type\": \"text\"}]\n```")
      [%{"name" => "status", "type" => "text", "widget" => "input", "list" => false}]

      iex> extract_variables("Just some SQL without variables")
      []
  """
  @spec extract_variables(String.t()) :: [map()]
  def extract_variables(content) do
    case Regex.run(~r/```variables\s*\n(.*?)\n```/s, content) do
      [_, json_str] ->
        case Lotus.JSON.decode(String.trim(json_str)) do
          {:ok, variables} when is_list(variables) ->
            Enum.map(variables, &normalize_variable/1)

          _ ->
            []
        end

      nil ->
        []
    end
  end

  @doc """
  Extract both SQL and variables from LLM response content.

  Combines `extract_sql/1` and `extract_variables/1` into a single call.
  This is the primary extraction entry point for response parsing.

  ## Parameters

  - `content` - Raw response content from the LLM

  ## Returns

  - `{:ok, %{sql: String.t(), variables: [map()]}}` - Successfully extracted
  - `{:error, {:unable_to_generate, reason}}` - LLM refused to generate

  ## Examples

      iex> extract_response("```sql\\nSELECT * FROM users WHERE status = {{status}}\\n```\\n```variables\\n[{\\"name\\": \\"status\\"}]\\n```")
      {:ok, %{sql: "SELECT * FROM users WHERE status = {{status}}", variables: [...]}}
  """
  @spec extract_response(String.t()) ::
          {:ok, %{sql: String.t(), variables: [map()]}}
          | {:error, {:unable_to_generate, String.t()}}
  def extract_response(content) do
    case extract_sql(content) do
      {:ok, sql} ->
        variables = extract_variables(content)
        {:ok, %{sql: sql, variables: variables}}

      {:error, _} = error ->
        error
    end
  end

  @valid_types ~w(text number date)

  defp normalize_variable(var) when is_map(var) do
    var
    |> normalize_type()
    |> Map.put_new("widget", "input")
    |> Map.put_new("list", false)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp normalize_type(%{"type" => type} = var) when type in @valid_types, do: var
  defp normalize_type(%{"type" => _} = var), do: Map.put(var, "type", "text")
  defp normalize_type(var), do: Map.put(var, "type", "text")

  # Core Lotus template DSL rules. Language-agnostic — they describe the
  # Lotus preprocessing layer (`substitute_variable`, `OptionalClause`),
  # not any specific query language. Emitted in every prompt regardless
  # of adapter or trust level.
  defp lotus_template_notes do
    """
    ## Lotus Template DSL (applies to every query language):

    **`{{variable_name}}` substitution.** Lotus replaces `{{name}}` with a
    language-appropriate form at execution time — a placeholder for
    prepared-statement drivers, a properly-escaped literal for JSON / DSL
    engines. You write `{{name}}` and let Lotus handle the shape.

    **List variables (`list: true`).** Write `{{variable}}` once in the
    position where the multiple values should appear. Do NOT wrap it in
    conversion functions like `STRING_TO_ARRAY()`, `SPLIT()`, etc. — Lotus
    expands it into the right shape for the target language (a grouped
    placeholder list for SQL, a JSON array for JSON DSLs).

    **`[[...]]` optional blocks.** Clauses inside double brackets are
    removed entirely when the variables they reference have no value.
    Structure the surrounding query so it stays syntactically valid when
    a block is stripped — the `Example Statement` below demonstrates the
    correct idiom for the target language.
    """
  end

  defp read_only_instructions(true) do
    """
    **IMPORTANT:** You can ONLY generate **read-only** SQL queries (SELECT, WITH, EXPLAIN, VALUES).
    Never generate INSERT, UPDATE, DELETE, DROP, CREATE, ALTER, TRUNCATE, or any other write/DDL statements.

    If asked about:
    - General information (recipes, weather, etc.)
    - Data not in available tables
    - Actions that modify data (inserting, updating, deleting records)
    - Any non-SELECT operation

    Respond with: "UNABLE_TO_GENERATE: [reason]"
    """
  end

  defp read_only_instructions(false) do
    """
    **IMPORTANT:** You can generate both read and write SQL queries, including SELECT, INSERT, UPDATE,
    DELETE, CREATE, ALTER, DROP, and other statements.

    If asked about:
    - General information (recipes, weather, etc.)
    - Data not in available tables

    Respond with: "UNABLE_TO_GENERATE: [reason]"
    """
  end
end
