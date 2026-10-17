if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.RunSQL do
    @moduledoc false
    use Sake.Tool,
      name: "run_sql",
      title: "Run a query",
      description:
        "Run a read-only statement (SQL, or the source's own query language) against a " <>
          "data source and return a page of its rows. Writes are refused. Page through a " <>
          "large result with limit and offset rather than asking for every row.",
      scope: "lotus:query",
      annotations: [read_only: true, idempotent: true, open_world: false],
      task: :optional

    arg :data_source, :string, required: true, description: "The data source's name"

    arg :statement, :string,
      required: true,
      max_length: 100_000,
      description: "The statement to run"

    arg :limit, :integer,
      default: 100,
      min: 1,
      description: "Rows to return (at most the server's cap, 500 by default)"

    arg :offset, :integer, default: 0, min: 0, max: 1_000_000, description: "Rows to skip"

    alias Lotus.MCP.Support

    @impl true
    def execute(%{data_source: ds, statement: statement} = args, ctx) do
      window = Support.window(args[:limit], args[:offset])

      with {:ok, ds} <- Support.data_source(ds),
           {:ok, result} <-
             Lotus.run_statement(
               statement,
               [],
               [repo: ds, read_only: true, window: window] ++ Support.actor_opts(ctx)
             ) do
        {:ok, Support.result(result, window)}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
