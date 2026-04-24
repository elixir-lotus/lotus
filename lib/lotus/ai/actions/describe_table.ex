defmodule Lotus.AI.Actions.DescribeTable do
  @moduledoc """
  Retrieves column details for a specific table.

  Returns column names, types, nullability, and primary key info.
  Accepts schema-qualified names (e.g., "reporting.customers").
  """

  @behaviour Lotus.AI.Action

  alias Lotus.Source
  alias Lotus.Source.Adapter

  @impl true
  def name, do: "describe_table"

  @impl true
  def description,
    do:
      "Get column details for a specific table including names, types, and constraints. " <>
        "Use schema-qualified names (e.g., 'reporting.customers') when tables exist in multiple schemas."

  @impl true
  def schema do
    [
      data_source: [type: :string, required: true, doc: "Name of the data source to query"],
      table_name: [
        type: :string,
        required: true,
        doc: "Schema-qualified table name (e.g., 'reporting.customers') or just table name"
      ]
    ]
  end

  @impl true
  def run(params, _context) do
    adapter = Source.resolve!(params.data_source, nil)

    with {:ok, {schema, table}} <- parse_name(adapter, params.table_name),
         :ok <- validate_parts(adapter, schema, table) do
      fetch_schema(params.data_source, schema, table, params.table_name)
    end
  end

  defp parse_name(adapter, table_name) do
    case Adapter.parse_qualified_name(adapter, table_name) do
      {:ok, [schema, table]} ->
        {:ok, {schema, table}}

      {:ok, [table]} ->
        {:ok, {nil, table}}

      {:ok, parts} ->
        {:error, "Unexpected hierarchy depth for #{inspect(table_name)}: #{inspect(parts)}"}

      {:error, _} = err ->
        err
    end
  end

  defp validate_parts(adapter, nil, table),
    do: Adapter.validate_identifier(adapter, :table, table)

  defp validate_parts(adapter, schema, table) do
    with :ok <- Adapter.validate_identifier(adapter, :schema, schema) do
      Adapter.validate_identifier(adapter, :table, table)
    end
  end

  defp fetch_schema(data_source, nil, table, original_name) do
    format_result(Lotus.Schema.describe_table(data_source, table), original_name)
  end

  defp fetch_schema(data_source, schema, table, original_name) do
    format_result(
      Lotus.Schema.describe_table(data_source, table, schema: schema),
      original_name
    )
  end

  defp format_result({:ok, columns}, table_name) do
    column_info =
      Enum.map(columns, fn col ->
        %{
          name: col.name,
          type: col.type,
          nullable: Map.get(col, :nullable, true),
          primary_key: Map.get(col, :primary_key, false)
        }
      end)

    {:ok, %{table: table_name, columns: column_info}}
  end

  defp format_result({:error, reason}, _table_name), do: {:error, reason}
end
