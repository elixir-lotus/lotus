if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.GetQuery do
    @moduledoc false
    use Sake.Tool,
      name: "get_query",
      title: "Get a saved query",
      description: "Get a saved query: its statement, variables and charts.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :id, :integer, required: true, description: "The saved query's id"

    alias Lotus.MCP.Support

    @impl true
    def execute(%{id: id}, _ctx) do
      case Support.fetch_query(id) do
        {:ok, query} -> {:ok, Support.query_detail(query)}
        {:error, message} -> {:error, message}
      end
    end
  end
end
