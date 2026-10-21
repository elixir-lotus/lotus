if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP do
    @moduledoc """
    An MCP server for Lotus, built on [Sake](https://hexdocs.pm/sake): it lets
    an MCP client (Claude Code, Claude Desktop, an agent) explore your data
    sources, run read-only queries, run saved queries and dashboards, and
    save queries, charts and dashboards, as the person signed in to your app.

    Compiled only when the host depends on `:sake`. Serve it on an endpoint of
    its own, or mount it in your app's own Sake server:

        # router.ex
        sake_endpoint "/lotus/mcp", server: Lotus.MCP, auth: true

        # or
        defmodule MyApp.MCP do
          use Sake.Server, name: "my-app", version: "1.0.0"
          mount Lotus.MCP, prefix: "lotus"
        end

    ## Scopes

      * `lotus:read` — list data sources, schemas, tables and columns, saved
        queries and dashboards.
      * `lotus:query` — run read-only statements, saved queries and dashboards,
        and read a column's distinct values.
      * `lotus:write` — save and change queries, charts and dashboards.

    Every statement runs read-only, whatever `config :lotus, read_only:` says,
    and through Lotus's visibility rules and middleware with the person as the
    actor; a statement that writes is not saved either. Nothing is deleted
    through MCP. Nobody may use it until `config :lotus, :mcp, authorize:`,
    or the serving server with `Lotus.MCP.Host`, says who.

    ## Configuration

        config :lotus, :mcp,
          # Required: who may use Lotus over MCP. Takes the signed-in
          # principal, returns true to allow. Without it, nobody may.
          authorize: {MyApp.Reporting, :lotus_user?},
          # The :context and :scope Lotus gets for the signed-in principal
          # (default: the principal as both).
          actor: {MyApp.Reporting, :lotus_actor},
          # Only these data sources (default: all).
          data_sources: ["analytics"],
          # The most rows a tool returns at once (default: 500).
          max_rows: 500

    See the MCP guide for authorization and connecting Claude Code.
    """

    use Sake.Server,
      name: "lotus",
      version: Mix.Project.config()[:version],
      instructions: """
      Lotus is this app's BI engine: data sources, saved queries, charts and dashboards.

      To answer a question about the data, look for a saved query or a dashboard that
      answers it first (list_queries, list_dashboards), and run it (run_query,
      run_dashboard). Otherwise explore with list_data_sources, list_tables and
      describe_table, and run your own read-only statement with run_sql; page through
      large results instead of asking for every row.

      To keep an answer, save the statement with save_query, chart it with save_chart,
      and put it on a dashboard with create_dashboard and add_dashboard_card. Saved
      queries, charts and dashboards appear in the Lotus web UI.
      """

    scope "lotus:read", "Browse data sources, tables, saved queries and dashboards"
    scope "lotus:query", "Run read-only queries, saved queries and dashboards"
    scope "lotus:write", "Save and change queries, charts and dashboards"

    tools [
      Lotus.MCP.Tools.ListDataSources,
      Lotus.MCP.Tools.ListSchemas,
      Lotus.MCP.Tools.ListTables,
      Lotus.MCP.Tools.DescribeTable,
      Lotus.MCP.Tools.GetColumnValues,
      Lotus.MCP.Tools.RunSQL,
      Lotus.MCP.Tools.ListQueries,
      Lotus.MCP.Tools.GetQuery,
      Lotus.MCP.Tools.RunQuery,
      Lotus.MCP.Tools.ListDashboards,
      Lotus.MCP.Tools.GetDashboard,
      Lotus.MCP.Tools.RunDashboard,
      Lotus.MCP.Tools.SaveQuery,
      Lotus.MCP.Tools.UpdateQuery,
      Lotus.MCP.Tools.SaveChart,
      Lotus.MCP.Tools.CreateDashboard,
      Lotus.MCP.Tools.AddDashboardCard
    ]

    resources [Lotus.MCP.Resources.Query, Lotus.MCP.Resources.Dashboard]

    middleware :after_list, [Lotus.MCP.Authorize]
  end
end
