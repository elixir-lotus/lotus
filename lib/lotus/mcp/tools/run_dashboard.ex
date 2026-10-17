if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.RunDashboard do
    @moduledoc false
    use Sake.Tool,
      name: "run_dashboard",
      title: "Run a dashboard",
      description:
        "Run every query card of a dashboard, read-only, and return each card's first " <>
          "rows. Give filter values by filter name; filters left out take their defaults.",
      scope: "lotus:query",
      annotations: [read_only: true, idempotent: true, open_world: false],
      task: :optional

    arg :id, :integer, required: true, description: "The dashboard's id"

    arg :filter_values, :any,
      description: ~s(Filter values by filter name, e.g. {"country": "PT"})

    arg :rows_per_card, :integer,
      default: 50,
      min: 1,
      description: "Rows to return for each card (at most the server's cap)"

    alias Lotus.MCP.Support

    @max_cards 50

    @impl true
    def execute(%{id: id} = args, ctx) do
      window = Support.window(args[:rows_per_card] || 50, 0)
      filter_values = Support.vars(args[:filter_values])

      with {:ok, dashboard} <- Support.fetch_dashboard(id),
           cards = Enum.filter(Support.dashboard_cards(dashboard), &(&1.card_type == :query)),
           :ok <- not_too_many(cards) do
        opts =
          [filter_values: filter_values, read_only: true, window: window] ++
            Support.actor_opts(ctx)

        # One card at a time, so that one run holds one of the source's
        # connections, not one for each card.
        {:ok,
         %{
           dashboard: Support.dashboard_summary(dashboard),
           cards: Enum.map(cards, &card_result(&1, Lotus.run_dashboard_card(&1, opts), window))
         }}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end

    defp not_too_many(cards) when length(cards) <= @max_cards, do: :ok

    defp not_too_many(_cards),
      do:
        {:error, "The dashboard has more than #{@max_cards} query cards: run them with run_query"}

    defp card_result(card, {:ok, result}, window) do
      %{
        id: card.id,
        title: card.title,
        query_id: card.query_id,
        chart: card.visualization_config,
        result: Support.result(result, window)
      }
    end

    defp card_result(card, {:error, reason}, _window),
      do: %{id: card.id, title: card.title, query_id: card.query_id, error: Support.error(reason)}
  end
end
