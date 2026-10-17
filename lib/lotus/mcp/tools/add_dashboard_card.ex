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
          "as a chart with chart_type and its fields), markdown text, or a heading. The " <>
          "dashboard's grid is 12 columns wide.",
      scope: "lotus:write",
      annotations: [read_only: false, destructive: false, idempotent: false, open_world: false]

    arg :dashboard_id, :integer, required: true, description: "The dashboard's id"

    arg :type, {:enum, ["query", "text", "heading"]},
      default: "query",
      description: "The card's type"

    arg :query_id, :integer, description: "query: the saved query the card shows"
    arg :title, :string, max_length: 255, description: "The card's title"
    arg :text, :string, max_length: 10_000, description: "text: markdown; heading: the heading"
    arg :width, :integer, default: 6, min: 1, max: 12, description: "Columns wide, of 12"
    arg :height, :integer, default: 4, min: 1, max: 24, description: "Rows high"

    arg :vars, :any,
      description: "query: values for the query's variables for the chart's check run"

    Chart.args()

    @impl true
    def execute(%{dashboard_id: id} = args, ctx) do
      actor = Support.actor_opts(ctx)

      with {:ok, dashboard} <- Support.fetch_dashboard(id),
           {:ok, attrs} <- attrs(args[:type] || "query", args, actor),
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

    defp attrs("query", %{query_id: query_id} = args, actor) when is_integer(query_id) do
      with {:ok, query} <- Support.fetch_query(query_id),
           {:ok, config} <- chart(query, args, actor) do
        {:ok,
         %{
           card_type: :query,
           query_id: query.id,
           title: args[:title] || query.name,
           visualization_config: config || %{}
         }}
      end
    end

    defp attrs("query", _args, _actor), do: {:error, "A query card needs query_id"}

    defp attrs(type, %{text: text} = args, _actor) when is_binary(text) do
      {:ok, %{card_type: card_type(type), title: args[:title], content: %{text: text}}}
    end

    defp attrs(type, _args, _actor), do: {:error, "A #{type} card needs text"}

    defp card_type("text"), do: :text
    defp card_type("heading"), do: :heading

    defp chart(_query, %{chart_type: nil}, _actor), do: {:ok, nil}
    defp chart(_query, args, _actor) when not is_map_key(args, :chart_type), do: {:ok, nil}

    defp chart(query, args, actor) do
      with {:ok, columns} <- Chart.query_columns(query, Support.vars(args[:vars]), actor),
           do: Chart.config(args, columns)
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
