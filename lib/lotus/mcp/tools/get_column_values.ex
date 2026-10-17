if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.GetColumnValues do
    @moduledoc false
    use Sake.Tool,
      name: "get_column_values",
      title: "Get a column's values",
      description:
        "Get up to 100 distinct values of a column, to learn what a status or category " <>
          "column holds before filtering on it.",
      scope: "lotus:query",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :data_source, :string, required: true, description: "The data source's name"

    arg :table, :string,
      required: true,
      description: "The table's name, schema-qualified if needed (e.g. public.users)"

    arg :column, :string, required: true, description: "The column's name"

    alias Lotus.AI.Actions.GetColumnValues
    alias Lotus.MCP.Support

    @impl true
    def execute(%{data_source: ds, table: table, column: column}, ctx) do
      with {:ok, ds} <- Support.data_source(ds),
           {:ok, result} <-
             GetColumnValues.run(
               %{data_source: ds, table_name: table, column_name: column},
               Map.new(Support.actor_opts(ctx))
             ) do
        {:ok, result}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
