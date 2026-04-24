defmodule Lotus.Source.Adapters.Ecto.SQL.Identifier do
  @moduledoc false

  # Regex for valid SQL identifiers: letters, digits, underscores.
  @valid_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/

  @doc """
  Parses a potentially schema-qualified table name into `{schema, table}`.

  Returns `{nil, table}` for unqualified names.
  """
  @spec parse_table_name(String.t()) :: {String.t() | nil, String.t()}
  def parse_table_name(table_name) do
    case String.split(table_name, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {nil, table}
    end
  end

  @doc """
  Validates that a string is a safe SQL identifier.

  Returns `:ok` if the identifier matches `[a-zA-Z_][a-zA-Z0-9_]*`,
  or `{:error, reason}` otherwise.
  """
  @spec validate_identifier(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_identifier(value, label) do
    if Regex.match?(@valid_identifier, value) do
      :ok
    else
      {:error,
       "Invalid #{label}: #{inspect(value)}. Must contain only letters, digits, and underscores."}
    end
  end

  @doc """
  Validates that a string is a safe SQL identifier, raising on failure.
  """
  @spec validate_identifier!(String.t(), String.t()) :: :ok
  def validate_identifier!(value, label) do
    case validate_identifier(value, label) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Validates all parts of a table reference (schema + table, or just table).
  """
  @spec validate_table_parts(String.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def validate_table_parts(nil, table), do: validate_identifier(table, "table name")

  def validate_table_parts(schema, table) do
    with :ok <- validate_identifier(schema, "schema name") do
      validate_identifier(table, "table name")
    end
  end

  @doc """
  Validates a Postgres search_path string.

  Splits on `,`, trims whitespace, and validates each part as an identifier.
  Raises `ArgumentError` if any part is invalid.
  """
  @spec validate_search_path!(String.t()) :: :ok
  def validate_search_path!(search_path) do
    search_path
    |> String.split(",")
    |> Enum.each(fn part ->
      part = String.trim(part)
      validate_identifier!(part, "search_path entry")
    end)
  end
end
