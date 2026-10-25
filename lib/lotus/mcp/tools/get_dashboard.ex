if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.GetDashboard do
    @moduledoc false
    use Sake.Tool,
      name: "get_dashboard",
      title: "Get a dashboard",
      description:
        "Get a dashboard: its cards (with their saved queries and charts) and filters.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :id, :integer, required: true, description: "The dashboard's id"

    alias Lotus.MCP.Support

    @impl true
    def execute(%{id: id}, ctx) do
      case Support.fetch_dashboard(id, ctx) do
        {:ok, dashboard} -> {:ok, Support.dashboard_detail(dashboard)}
        {:error, message} -> {:error, message}
      end
    end
  end
end
