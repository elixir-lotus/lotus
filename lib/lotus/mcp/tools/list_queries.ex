if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.ListQueries do
    @moduledoc false
    use Sake.Tool,
      name: "list_queries",
      title: "List saved queries",
      description:
        "List the saved queries (the first 200), optionally those whose name contains " <>
          "a search term; search to narrow a long list. " <>
          "Use get_query for a query's statement and charts, run_query to run it.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    arg :search, :string, description: "Only queries whose name contains this (case-insensitive)"

    alias Lotus.MCP.Support

    @impl true
    def execute(args, ctx) do
      queries =
        case args[:search] do
          nil -> Lotus.list_queries(Support.actor_opts(ctx))
          term -> Lotus.Storage.list_queries_by([search: term] ++ Support.actor_opts(ctx))
        end

      exposed = Enum.filter(queries, &Support.exposed?/1)

      {:ok,
       %{
         queries:
           exposed |> Enum.take(Support.list_limit()) |> Enum.map(&Support.query_summary/1),
         truncated: length(exposed) > Support.list_limit()
       }}
    end
  end
end
