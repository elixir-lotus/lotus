if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.ListTables do
    @moduledoc false
    use Sake.Tool,
      name: "list_tables",
      title: "List tables",
      description:
        "List the tables of a data source that may be queried, schema-qualified where " <>
          "the source has schemas (e.g. public.users), and approx_rows: each table's " <>
          "estimated row count from the database's statistics, where it has one. Use it " <>
          "to tell large tables from small ones and pick a limit.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :data_source, :string, required: true, description: "The data source's name"

    alias Lotus.AI.Actions.ListTables
    alias Lotus.MCP.Support

    @impl true
    def execute(%{data_source: ds}, ctx) do
      with {:ok, ds} <- Support.data_source(ds),
           {:ok, result} <- ListTables.run(%{data_source: ds}, Map.new(Support.actor_opts(ctx))) do
        {:ok, result}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
