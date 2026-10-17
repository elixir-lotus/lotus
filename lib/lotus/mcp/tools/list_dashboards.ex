if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.ListDashboards do
    @moduledoc false
    use Sake.Tool,
      name: "list_dashboards",
      title: "List dashboards",
      description:
        "List the dashboards (the first 200), optionally those whose name contains a " <>
          "search term; search to narrow a long list. " <>
          "Use get_dashboard for a dashboard's cards and filters, run_dashboard to run it.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :search, :string,
      description: "Only dashboards whose name contains this (case-insensitive)"

    alias Lotus.MCP.Support

    @impl true
    def execute(args, _ctx) do
      dashboards =
        case args[:search] do
          nil -> Lotus.list_dashboards()
          term -> Lotus.list_dashboards_by(search: term)
        end

      {:ok,
       %{
         dashboards:
           dashboards |> Enum.take(Support.list_limit()) |> Enum.map(&Support.dashboard_summary/1),
         truncated: length(dashboards) > Support.list_limit()
       }}
    end
  end
end
