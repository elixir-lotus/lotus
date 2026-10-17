if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.CreateDashboard do
    @moduledoc false
    use Sake.Tool,
      name: "create_dashboard",
      title: "Create a dashboard",
      description: "Create an empty dashboard. Add cards to it with add_dashboard_card.",
      scope: "lotus:write",
      annotations: [read_only: false, destructive: false, idempotent: false, open_world: false]

    arg :name, :string, required: true, max_length: 255, description: "The dashboard's name"

    arg :description, :string,
      max_length: 2000,
      description:
        "What the dashboard is for: Markdown with inline formats only (bold, italic, " <>
          "strikethrough, code, links), no headings, lists or blocks, which Lotus Web's " <>
          "editor would flatten"

    alias Lotus.MCP.Support

    @impl true
    def execute(args, ctx) do
      case Lotus.create_dashboard(
             %{name: args.name, description: args[:description]},
             Keyword.take(Support.actor_opts(ctx), [:context])
           ) do
        {:ok, dashboard} -> {:ok, Support.dashboard_detail(dashboard)}
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
