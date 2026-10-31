if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.AddDashboardCard do
    @moduledoc false
    alias Lotus.MCP.{Chart, Support}
    require Chart

    use Sake.Tool,
      name: "add_dashboard_card",
      title: "Add a card to a dashboard",
      description:
        "Add a card below a dashboard's other cards: a saved query (shown as a table, or " <>
          "as a chart with chart_type and its fields, which runs the query once and needs " <>
          "the lotus:query scope), markdown text, or a heading. The dashboard's grid is 12 " <>
          "columns wide.",
      scope: "lotus:write",
      annotations: [read_only: false, destructive: false, idempotent: false, open_world: false]

    arg :dashboard_id, :integer, required: true, description: "The dashboard's id"

    arg :type, {:enum, ["query", "text", "heading"]},
      default: "query",
      description: "The card's type"

    arg :query_id, :integer, description: "query: the saved query the card shows"
    arg :title, :string, max_length: 255, description: "The card's title"

    arg :text, :string,
      max_length: 10_000,
      description:
        "text: GitHub Flavored Markdown (headings, lists, check lists, quotes, code, " <>
          "tables, links); heading: plain text"

    arg :width, :integer, default: 6, min: 1, max: 12, description: "Columns wide, of 12"
    arg :height, :integer, default: 4, min: 1, max: 24, description: "Rows high"

    arg :vars, :any,
      description: "query: values for the query's variables for the chart's check run"

    Chart.args()

    @impl true
    def execute(%{dashboard_id: id} = args, ctx) do
      actor = Support.actor_opts(ctx)

      with {:ok, dashboard} <- Support.fetch_dashboard(id, ctx),
           {:ok, attrs} <- attrs(args[:type] || "query", args, actor, ctx),
           cards = Lotus.list_dashboard_cards(dashboard.id),
           {:ok, card} <-
             Lotus.create_dashboard_card(
               dashboard.id,
               Map.merge(attrs, placement(cards, args)),
               Keyword.take(actor, [:context])
             ) do
        {:ok, %{dashboard_id: dashboard.id, card: Support.card(card)}}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end

    defp attrs("query", %{query_id: query_id} = args, actor, ctx) when is_integer(query_id) do
      with {:ok, query} <- Support.fetch_query(query_id, actor),
           {:ok, config} <- chart(query, args, actor, ctx) do
        {:ok,
         %{
           card_type: :query,
           query_id: query.id,
           title: args[:title] || query.name,
           visualization_config: config || %{}
         }}
      end
    end

    defp attrs("query", _args, _actor, _ctx), do: {:error, "A query card needs query_id"}

    defp attrs(type, %{text: text} = args, _actor, _ctx) when is_binary(text) do
      {:ok, %{card_type: card_type(type), title: args[:title], content: %{text: text}}}
    end

    defp attrs(type, _args, _actor, _ctx), do: {:error, "A #{type} card needs text"}

    defp card_type("text"), do: :text
    defp card_type("heading"), do: :heading

    defp chart(_query, %{chart_type: nil}, _actor, _ctx), do: {:ok, nil}
    defp chart(_query, args, _actor, _ctx) when not is_map_key(args, :chart_type), do: {:ok, nil}

    # The chart's check runs the query, which takes the scope that runs one.
    defp chart(query, args, actor, ctx) do
      if Sake.Server.allowed?(%Sake.Tool.Spec{scopes: ["lotus:query"]}, ctx) do
        with {:ok, columns} <- Chart.query_columns(query, Support.vars(args[:vars]), actor),
             do: Chart.config(args, columns)
      else
        {:error, "A chart runs its query to check its fields, which needs the lotus:query scope"}
      end
    end

    # Below every card, at the left edge.
    defp placement(cards, args) do
      y =
        cards
        |> Enum.map(fn
          %{layout: %{y: y, h: h}} -> y + h
          _card -> 0
        end)
        |> Enum.max(fn -> 0 end)

      %{
        position: length(cards),
        layout: %{x: 0, y: y, w: args[:width] || 6, h: args[:height] || 4}
      }
    end
  end
end
