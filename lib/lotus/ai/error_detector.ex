defmodule Lotus.AI.ErrorDetector do
  @moduledoc """
  Analyzes SQL query errors and provides actionable suggestions.

  Classifies different types of database errors and generates helpful
  suggestions to guide the AI in fixing the query.

  ## Error Types

  - `:column_not_found` - Referenced column doesn't exist
  - `:table_not_found` - Referenced table doesn't exist
  - `:syntax_error` - SQL syntax is invalid
  - `:type_mismatch` - Data type incompatibility
  - `:ambiguous_column` - Column name is ambiguous in JOIN
  - `:permission_denied` - Access denied to table/column
  - `:unknown` - Other unclassified errors

  ## Usage

      error_context = ErrorDetector.analyze_error(
        "column 'status' does not exist",
        "SELECT status FROM users",
        %{tables_analyzed: ["users"]}
      )

      error_context.error_type
      # => :column_not_found

      error_context.suggestions
      # => ["Use describe_table() to see available columns", ...]
  """

  @type error_type ::
          :column_not_found
          | :table_not_found
          | :syntax_error
          | :type_mismatch
          | :ambiguous_column
          | :permission_denied
          | :unknown

  @type error_context :: %{
          error_type: error_type(),
          error_message: String.t(),
          failed_sql: String.t() | nil,
          suggestions: [String.t()]
        }

  @doc """
  Analyze a query error and generate actionable suggestions.

  ## Parameters

  - `error_message` - The error message from the database
  - `sql` - The SQL query that failed (optional)
  - `source_context` - Context about tables analyzed (optional)

  ## Returns

  Map containing error type, message, failed SQL, and suggestions for fixing.

  ## Examples

      iex> result = ErrorDetector.analyze_error(
      ...>   "column 'status' does not exist",
      ...>   "SELECT status FROM users",
      ...>   %{tables_analyzed: ["users"]}
      ...> )
      iex> result.error_type
      :column_not_found
      iex> result.error_message
      "column 'status' does not exist"
      iex> result.failed_sql
      "SELECT status FROM users"
      iex> Enum.any?(result.suggestions, &String.contains?(&1, "describe_table"))
      true

  ## Adapter-supplied hints

  An optional fourth argument — `ai_context` — accepts the sanitized map
  returned by `Lotus.Source.Adapter.ai_context/1`. When present, its
  `:error_patterns` are matched against the error message; each
  matching pattern's `:hint` is prepended to the suggestions list.

  Untrusted adapters have their `:error_patterns` stripped upstream
  (by the `ai_context` dispatch helper) to `[]`, so no adapter-
  contributed text reaches users from untrusted sources — the fall-back
  is the generic classification + suggestion flow.
  """
  @spec analyze_error(String.t(), String.t() | nil, map(), map() | nil) :: error_context()
  def analyze_error(error_message, sql \\ nil, source_context \\ %{}, ai_context \\ nil) do
    error_type = classify_error(error_message)
    generic_suggestions = suggest_fixes(error_type, error_message, sql, source_context)
    adapter_hints = match_adapter_error_patterns(ai_context, error_message)

    %{
      error_type: error_type,
      error_message: error_message,
      failed_sql: sql,
      suggestions: adapter_hints ++ generic_suggestions
    }
  end

  # Pull hints from the adapter's `ai_context.error_patterns` for patterns
  # that match the error message. For untrusted adapters,
  # `Lotus.Source.Adapter.ai_context/1` has already stripped this list
  # to `[]` — so `match_adapter_error_patterns/2` returns an empty list
  # and we fall back to the generic suggestions. There is no unsafe
  # adapter-contributed text that reaches the user.
  defp match_adapter_error_patterns(nil, _error_message), do: []

  defp match_adapter_error_patterns(ai_context, error_message) when is_map(ai_context) do
    ai_context
    |> Map.get(:error_patterns, [])
    |> Enum.filter(fn
      %{pattern: %Regex{} = re} -> Regex.match?(re, error_message)
      _ -> false
    end)
    |> Enum.map(fn %{hint: hint} -> hint end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc """
  Classify the type of error based on the error message.

  ## Examples

      iex> ErrorDetector.classify_error("column 'foo' does not exist")
      :column_not_found

      iex> ErrorDetector.classify_error("relation 'bar' does not exist")
      :table_not_found

      iex> ErrorDetector.classify_error("syntax error at or near 'SELECT'")
      :syntax_error
  """
  @spec classify_error(String.t()) :: error_type()
  def classify_error(error_message) do
    error_lower = String.downcase(error_message)

    cond do
      column_not_found_error?(error_lower) -> :column_not_found
      table_not_found_error?(error_lower) -> :table_not_found
      syntax_error?(error_lower) -> :syntax_error
      type_mismatch_error?(error_lower) -> :type_mismatch
      ambiguous_column_error?(error_lower) -> :ambiguous_column
      permission_denied_error?(error_lower) -> :permission_denied
      true -> :unknown
    end
  end

  @doc """
  Generate helpful suggestions for fixing the error.

  ## Parameters

  - `error_type` - Classified error type
  - `error_message` - Original error message
  - `sql` - Failed SQL query (optional)
  - `source_context` - Source context map (optional)

  ## Returns

  List of actionable suggestion strings.
  """
  @spec suggest_fixes(error_type(), String.t(), String.t() | nil, map()) :: [String.t()]
  def suggest_fixes(error_type, error_message, sql, source_context)

  def suggest_fixes(:column_not_found, error_message, _sql, source_context) do
    # Try to extract column name from error
    column_name = extract_identifier(error_message, "column")
    tables = source_context[:tables_analyzed] || []

    base_suggestions = [
      "The column name in the error message might not exist in the table"
    ]

    table_suggestions =
      if tables != [] do
        table_list = Enum.join(tables, "', '")

        [
          "Use describe_table('#{Enum.at(tables, 0)}') to see the actual column names for tables you've analyzed: '#{table_list}'",
          "The column might have a different name (check for similar names, pluralization, or prefixes)"
        ]
      else
        [
          "Use describe_table() to see the actual column names for the table you're querying",
          "The column name might be different (e.g., with underscores, different spelling, or a prefix)"
        ]
      end

    additional_suggestions =
      if column_name do
        [
          "Looking for '#{column_name}'? Check if it exists in a different table or has a different name",
          "Verify you're querying the correct table - the column might exist elsewhere"
        ]
      else
        [
          "Verify you're querying the correct table - the column might exist elsewhere"
        ]
      end

    (base_suggestions ++ table_suggestions ++ additional_suggestions)
    |> Enum.reject(&is_nil/1)
  end

  def suggest_fixes(:table_not_found, error_message, _sql, _source_context) do
    table_name = extract_identifier(error_message, "table", "relation")

    base_suggestions = [
      "The table referenced in the query doesn't exist in the database",
      "Use list_tables() to see all available tables",
      "Check if you're using the correct schema-qualified name (e.g., 'public.users' instead of 'users')"
    ]

    table_suggestions =
      if table_name do
        [
          "Looking for '#{table_name}'? It might have a different name or be in a different schema",
          "Check for typos, pluralization differences, or prefixes in the table name"
        ]
      else
        []
      end

    base_suggestions ++ table_suggestions
  end

  def suggest_fixes(:syntax_error, error_message, sql, _source_context) do
    base_suggestions = [
      "There's a SQL syntax error in the query",
      "Review the SQL syntax carefully - check for missing/extra commas, parentheses, or keywords"
    ]

    sql_suggestions =
      if sql do
        [
          "Review the generated SQL and fix any syntax issues",
          "Common issues: missing FROM clause, incorrect JOIN syntax, or misplaced keywords"
        ]
      else
        []
      end

    error_suggestions =
      if String.contains?(error_message, "near") do
        ["Pay attention to the syntax near: #{extract_near_context(error_message)}"]
      else
        []
      end

    (base_suggestions ++ sql_suggestions ++ error_suggestions)
    |> Enum.reject(&is_nil/1)
  end

  def suggest_fixes(:type_mismatch, _error_message, _sql, _source_context) do
    [
      "There's a data type mismatch in the query",
      "Check that you're comparing compatible types (e.g., don't compare strings to numbers without casting)",
      "Use appropriate type casting functions (CAST, ::type in PostgreSQL)",
      "Verify that function arguments have the correct types"
    ]
  end

  def suggest_fixes(:ambiguous_column, error_message, _sql, _source_context) do
    column_name = extract_identifier(error_message, "column")

    base_suggestions = [
      "A column name is ambiguous - it exists in multiple tables in your JOIN",
      "Qualify all column names with table names or aliases (e.g., users.id, u.name)"
    ]

    column_suggestions =
      if column_name do
        [
          "The ambiguous column is '#{column_name}' - prefix it with the table name (table_name.#{column_name})"
        ]
      else
        []
      end

    base_suggestions ++ column_suggestions
  end

  def suggest_fixes(:permission_denied, _error_message, _sql, _source_context) do
    [
      "You don't have permission to access this table or column",
      "Use list_tables() to see which tables are accessible",
      "Try querying a different table that you have access to",
      "Contact your database administrator if you need access to this resource"
    ]
  end

  def suggest_fixes(:unknown, error_message, _sql, _source_context) do
    [
      "An unexpected error occurred: #{error_message}",
      "Review the error message carefully and adjust the query accordingly",
      "You may need to use different functions or approach the problem differently"
    ]
  end

  # Private helpers

  # Error type classification helpers
  defp column_not_found_error?(error_lower) do
    String.contains?(error_lower, "column") and
      (String.contains?(error_lower, "does not exist") or
         String.contains?(error_lower, "not found") or
         String.contains?(error_lower, "unknown column"))
  end

  defp table_not_found_error?(error_lower) do
    (String.contains?(error_lower, "table") or String.contains?(error_lower, "relation")) and
      (String.contains?(error_lower, "does not exist") or
         String.contains?(error_lower, "doesn't exist") or
         String.contains?(error_lower, "not found"))
  end

  defp syntax_error?(error_lower) do
    String.contains?(error_lower, "syntax error") or
      String.contains?(error_lower, "syntax") or
      String.contains?(error_lower, "unexpected")
  end

  defp type_mismatch_error?(error_lower) do
    String.contains?(error_lower, "type") and
      (String.contains?(error_lower, "mismatch") or
         String.contains?(error_lower, "cannot") or
         String.contains?(error_lower, "invalid"))
  end

  defp ambiguous_column_error?(error_lower) do
    String.contains?(error_lower, "ambiguous")
  end

  defp permission_denied_error?(error_lower) do
    String.contains?(error_lower, "permission") or
      String.contains?(error_lower, "access denied") or
      String.contains?(error_lower, "not authorized")
  end

  # Extract identifier (table/column name) from error message
  defp extract_identifier(error_message, keyword1, keyword2 \\ nil) do
    keywords = [keyword1, keyword2] |> Enum.reject(&is_nil/1)

    # Try to match quoted identifier: 'name' or "name"
    case Regex.run(~r/['"]([^'"]+)['"]/, error_message) do
      [_, identifier] ->
        identifier

      nil ->
        # Try to extract based on keywords
        Enum.find_value(keywords, fn keyword ->
          case Regex.run(~r/#{keyword}\s+([a-zA-Z0-9_]+)/i, error_message) do
            [_, identifier] -> identifier
            nil -> nil
          end
        end)
    end
  end

  # Extract context around "near" in syntax errors
  defp extract_near_context(error_message) do
    case Regex.run(~r/near\s+(.+?)(?:\s+at|$)/i, error_message) do
      [_, context] -> String.trim(context)
      nil -> "the indicated position"
    end
  end
end
