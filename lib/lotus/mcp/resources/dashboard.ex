if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Resources.Dashboard do
    @moduledoc false
    use Sake.Resource,
      uri: "lotus://dashboards/{id}",
      name: "dashboard",
      title: "Dashboard",
      description: "A dashboard: its cards and filters.",
      mime_type: "application/json",
      scope: "lotus:read"

    alias Lotus.MCP.Support

    @impl true
    def read(%{id: id}, ctx) do
      with {id, ""} <- Integer.parse(id),
           {:ok, dashboard} <- Support.fetch_dashboard(id, ctx) do
        {:ok, Support.dashboard_detail(dashboard)}
      else
        _ -> {:error, :not_found}
      end
    end

    @impl true
    def list(ctx) do
      for dashboard <-
            Enum.take(Lotus.list_dashboards(Support.actor_opts(ctx)), Support.list_limit()) do
        %{
          uri: "lotus://dashboards/#{dashboard.id}",
          name: dashboard.name,
          description: dashboard.description
        }
      end
    end
  end
end
