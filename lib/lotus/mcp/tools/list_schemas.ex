if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.ListSchemas do
    @moduledoc false
    use Sake.Tool,
      name: "list_schemas",
      title: "List schemas",
      description: "List the schemas of a data source (e.g. public, reporting).",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :data_source, :string, required: true, description: "The data source's name"

    alias Lotus.AI.Actions.ListSchemas
    alias Lotus.MCP.Support

    @impl true
    def execute(%{data_source: ds}, ctx) do
      with {:ok, ds} <- Support.data_source(ds),
           {:ok, result} <- ListSchemas.run(%{data_source: ds}, Map.new(Support.actor_opts(ctx))) do
        {:ok, result}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
