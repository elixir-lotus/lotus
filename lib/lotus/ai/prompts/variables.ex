defmodule Lotus.AI.Prompts.Variables do
  @moduledoc """
  Source-agnostic variable system documentation for AI prompts.

  Describes the Lotus variable framework (syntax, widget types, list expansion,
  config fields) independently of any query language. Query-language-specific
  prompt modules (e.g. `QueryGeneration`) call into this module and may append
  language-specific notes.
  """

  @doc """
  Returns the framework-level variable documentation block to embed in a
  system prompt.

  Covers syntax, config fields, widget guidelines, list expansion behaviour,
  and the expected response format.
  """
  @spec system_docs() :: String.t()
  def system_docs do
    """
    ## Query Variables (Parameterization):
    Only add variables when the user explicitly asks for parameterization, filters,
    dropdowns, selectable inputs, or similar. NEVER add variables proactively.

    **Syntax:** Use `{{variable_name}}` placeholders in queries.

    **Variable config fields:**
    - `name` (required) — matches the `{{name}}` in the query
    - `type` (required) — `text`, `number`, or `date`
    - `widget` — `input` (free-form) or `select` (dropdown). Default: `input`
    - `label` — human-friendly label for the UI
    - `default` — fallback value if none provided. **For `list: true` variables, use a comma-separated string** (e.g., `"Alice, Bob"`)
    - `list` — `true` when the variable accepts multiple values. Default: `false`
    - `static_options` — array of `{"value": "...", "label": "..."}` objects for select widgets
    - `options_query` — query that returns `value` and `label` columns for dynamic options

    **Widget guidelines:**
    - Use `input` for free-form text, numbers, or dates
    - Use `select` when a column has a finite set of known values
    - `list: true` works with any widget and type — it means the variable accepts multiple values
    - With `input`: user enters comma-separated values
    - With `select`: user picks multiple options from a dropdown
    - **CRITICAL:** When `widget` is `select`, you MUST provide either `static_options` or `options_query`. A select widget without options is broken and unusable. NEVER emit `"widget": "select"` without also providing one of these.

    **List variable expansion:**
    When `list: true`, the system automatically expands `{{variable}}` into multiple
    parameter placeholders at execution time. You do NOT need to handle the expansion
    yourself — just use `{{variable}}` as a single placeholder and the framework does the rest.

    **Options strategy:**
    - Default to `static_options` with values discovered via `get_column_values()` when there are roughly 20 or fewer distinct values
    - Use `options_query` when the column references another table (e.g., foreign keys like user_id → users), when values are numerous or change frequently, or when the user explicitly asks for dynamic/SQL-based options
    - `options_query` must return exactly two columns aliased as `value` and `label`
    - When unsure whether to use static or dynamic options, prefer `options_query` — it always stays up to date

    ## Optional Variables (`[[...]]` syntax):
    When a query has filters that should only apply when the user provides a value,
    wrap those clauses in double brackets `[[...]]`. If the enclosed variable has no
    value (missing, nil, or empty string), the entire `[[...]]` block is removed from
    the query. If all variables inside the block have values, the brackets are stripped
    and the clause is kept.

    **Rules:**
    - Structure the surrounding query so it stays syntactically valid when `[[...]]` blocks
      are stripped. The idiom is language-specific — follow the `Example Statement` supplied
      by the target adapter
    - Each `[[...]]` block is independent — one block being removed does not affect others
    - A block with multiple variables requires ALL of them to have values; otherwise the block is removed
    - Variables can appear both inside and outside `[[...]]` blocks — outside variables are always required
    - Only wrap the conditional fragment, not the entire surrounding clause
    - Use optional variables when the user asks for "optional filters", "dynamic filters",
      "filters that can be left empty", or similar phrasing

    **When to use optional variables:**
    - User asks for a query where some filters are optional or can be left blank
    - User wants a single query that works with or without certain filters
    - User asks for a "search" or "filter" form where not all fields are required

    **Response format when variables are used:**
    Include BOTH a ```sql block AND a ```variables JSON block:
    #{examples()}

    When no variables are needed, return ONLY the query block as usual.
    """
  end

  defp examples do
    """
    Example with static options (for enums/status columns):
    ```sql
    SELECT * FROM orders WHERE status = {{status}}
    ```

    ```variables
    [
      {
        "name": "status",
        "type": "text",
        "widget": "select",
        "label": "Order Status",
        "static_options": [
          {"value": "pending", "label": "Pending"},
          {"value": "shipped", "label": "Shipped"}
        ]
      }
    ]
    ```

    Example with list variable (multiple values):
    ```sql
    SELECT * FROM users WHERE "name" IN ({{names}})
    ```

    ```variables
    [
      {
        "name": "names",
        "type": "text",
        "widget": "input",
        "label": "User Names",
        "list": true,
        "default": "Alice, Bob"
      }
    ]
    ```

    Example with optional filters (user can leave them blank):
    ```sql
    SELECT "id", "name", "email", "status"
    FROM public.users
    WHERE 1=1
      [[AND "name" ILIKE '%' || {{name}} || '%']]
      [[AND "status" = {{status}}]]
    ORDER BY "created_at" DESC
    LIMIT 100
    ```

    ```variables
    [
      {
        "name": "name",
        "type": "text",
        "widget": "input",
        "label": "Name (optional)"
      },
      {
        "name": "status",
        "type": "text",
        "widget": "select",
        "label": "Status (optional)",
        "static_options": [
          {"value": "active", "label": "Active"},
          {"value": "inactive", "label": "Inactive"}
        ]
      }
    ]
    ```

    Example with options_query (for foreign keys/dynamic data):
    ```sql
    SELECT * FROM orders WHERE "user_id" IN ({{user_ids}})
    ```

    ```variables
    [
      {
        "name": "user_ids",
        "type": "number",
        "widget": "select",
        "label": "Select Users",
        "list": true,
        "options_query": "SELECT \\"id\\" AS value, \\"name\\" AS label FROM public.users ORDER BY \\"name\\""
      }
    ]
    ```
    """
  end
end
