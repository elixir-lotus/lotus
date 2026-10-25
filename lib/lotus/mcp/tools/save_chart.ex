if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.SaveChart do
    @moduledoc false
    alias Lotus.MCP.{Chart, Support}
    require Chart

    use Sake.Tool,
      name: "save_chart",
      title: "Chart a saved query",
      description:
        "Set a saved query's chart, as Lotus shows it with the query. The query runs once " <>
          "(one row) to check that the chart's fields are columns of its result.",
      scope: "lotus:write",
      annotations: [read_only: false, destructive: true, idempotent: true, open_world: false]

    arg :query_id, :integer, required: true, description: "The saved query's id"

    arg :vars, :any,
      description: "Values for the query's variables for the check run, if it needs any"

    Chart.args()

    @impl true
    def execute(%{query_id: id} = args, ctx) do
      actor = Support.actor_opts(ctx)

      with :ok <- chart_type(args),
           {:ok, query} <- Support.fetch_query(id, ctx),
           {:ok, columns} <- Chart.query_columns(query, Support.vars(args[:vars]), actor),
           {:ok, config} <- Chart.config(args, columns),
           {:ok, viz} <- save(query, config, Keyword.take(actor, [:context])) do
        {:ok, %{query_id: query.id, chart: %{id: viz.id, name: viz.name, config: viz.config}}}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end

    defp chart_type(%{chart_type: type}) when is_binary(type), do: :ok
    defp chart_type(_args), do: {:error, "chart_type is required"}

    # The query's first chart is the one Lotus Web shows and edits.
    defp save(query, config, opts) do
      case Lotus.list_visualizations(query.id) do
        [] ->
          Lotus.create_visualization(
            query.id,
            %{name: "Default", position: 0, config: config},
            opts
          )

        [existing | _] ->
          Lotus.update_visualization(existing, %{config: config}, opts)
      end
    end
  end
end
