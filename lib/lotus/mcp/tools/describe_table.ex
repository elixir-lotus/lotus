if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.DescribeTable do
    @moduledoc false
    use Sake.Tool,
      name: "describe_table",
      title: "Describe a table",
      description:
        "Describe a table's columns: name, type, whether it is nullable, whether it is " <>
          "part of the primary key, the column a foreign key references (references: " <>
          "'schema.table.column': join on it rather than guess from names), and the " <>
          "column's comment where it has one.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :data_source, :string, required: true, description: "The data source's name"

    arg :table, :string,
      required: true,
      description: "The table's name, schema-qualified if needed (e.g. public.users)"

    alias Lotus.AI.Actions.DescribeTable
    alias Lotus.MCP.Support

    @impl true
    def execute(%{data_source: ds, table: table}, ctx) do
      with {:ok, ds} <- Support.data_source(ds),
           {:ok, result} <-
             DescribeTable.run(
               %{data_source: ds, table_name: table},
               Map.new(Support.actor_opts(ctx))
             ) do
        {:ok, result}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
