if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.RunQuery do
    @moduledoc false
    use Sake.Tool,
      name: "run_query",
      title: "Run a saved query",
      description:
        "Run a saved query, read-only, and return a page of its rows. Give values for " <>
          "its variables in vars (by variable name); variables left out take their defaults.",
      scope: "lotus:query",
      annotations: [read_only: true, idempotent: true, open_world: false],
      task: :optional

    arg :id, :integer, required: true, description: "The saved query's id"

    arg :vars, :any,
      description: ~s(Variable values by name, e.g. {"status": "active", "min_total": 100})

    arg :limit, :integer,
      default: 100,
      min: 1,
      description: "Rows to return (at most the server's cap, 500 by default)"

    arg :offset, :integer, default: 0, min: 0, max: 1_000_000, description: "Rows to skip"

    alias Lotus.MCP.Support

    @impl true
    def execute(%{id: id} = args, ctx) do
      window = Support.window(args[:limit], args[:offset])

      with {:ok, query} <- Support.fetch_query(id),
           {:ok, result} <-
             Lotus.run_query(
               query,
               [read_only: true, vars: Support.vars(args[:vars]), window: window] ++
                 Support.actor_opts(ctx)
             ) do
        {:ok, Support.result(result, window)}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
