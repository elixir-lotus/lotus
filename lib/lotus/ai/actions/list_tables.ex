defmodule Lotus.AI.Actions.ListTables do
  @moduledoc """
  Lists all available tables in a database.

  Returns schema-qualified table names (e.g., "public.users", "reporting.customers")
  for databases with schemas, or plain table names for schema-less databases.
  """

  @behaviour Lotus.AI.Action

  import Lotus.AI.Action, only: [actor_opts: 1]

  @impl true
  def name, do: "list_tables"

  @impl true
  def description,
    do:
      "Get list of all available tables in the database with their schemas " <>
        "(e.g., 'public.users', 'reporting.customers'), and approx_rows: an estimate " <>
        "of each table's row count from the database's statistics, where it has one"

  @impl true
  def schema do
    [
      data_source: [type: :string, required: true, doc: "Name of the data source to query"]
    ]
  end

  @impl true
  def run(params, context) do
    case Lotus.Schema.list_tables(params.data_source, actor_opts(context)) do
      {:ok, tables} ->
        names = format_table_names(tables)
        {:ok, with_estimates(%{tables: names}, names, params.data_source, context)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_table_names(tables) do
    Enum.map(tables, fn
      {schema, table} when not is_nil(schema) -> "#{schema}.#{table}"
      table -> table
    end)
  end

  # The engine's row count estimates, for the tables listed: a caller that
  # knows a table is large picks a limit. A source without them, or a
  # failure to read them, leaves approx_rows out.
  defp with_estimates(result, names, data_source, context) do
    case Lotus.Schema.table_row_estimates(data_source, actor_opts(context)) do
      {:ok, estimates} when map_size(estimates) > 0 ->
        listed = MapSet.new(names)

        approx =
          for {{schema, table}, rows} <- estimates,
              name = format_table_name(schema, table),
              MapSet.member?(listed, name),
              into: %{},
              do: {name, rows}

        if approx == %{}, do: result, else: Map.put(result, :approx_rows, approx)

      _ ->
        result
    end
  rescue
    _ -> result
  end

  defp format_table_name(nil, table), do: table
  defp format_table_name(schema, table), do: "#{schema}.#{table}"
end
