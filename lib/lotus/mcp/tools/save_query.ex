if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.SaveQuery do
    @moduledoc false
    use Sake.Tool,
      name: "save_query",
      title: "Save a query",
      description:
        "Save a statement as a new saved query, to run again later and to chart. Write " <>
          "{{name}} in the statement for a variable and declare it in variables. Run the " <>
          "statement with run_sql first to check it.",
      scope: "lotus:write",
      annotations: [read_only: false, destructive: false, idempotent: false, open_world: false]

    arg :name, :string, required: true, max_length: 255, description: "The query's name"
    arg :statement, :string, required: true, max_length: 100_000, description: "The statement"
    arg :data_source, :string, required: true, description: "The data source it runs against"
    arg :description, :string, max_length: 2000, description: "What the query answers"

    arg :variables, {:array, :any},
      description:
        ~s(The variables the statement uses, e.g. [{"name": "status", "type": "text", ) <>
          ~s("default": "active", "label": "Status"}]. type is text, number or date; ) <>
          ~s(list: true takes a list of values.)

    alias Lotus.MCP.Support

    @impl true
    def execute(args, ctx) do
      with {:ok, ds} <- Support.data_source(args.data_source),
           :ok <- Support.read_only_statement(args.statement, ds),
           {:ok, variables} <- Support.variables(args[:variables]),
           {:ok, query} <-
             Lotus.create_query(
               %{
                 name: args.name,
                 statement: args.statement,
                 data_source: ds,
                 description: args[:description],
                 variables: variables
               },
               Keyword.take(Support.actor_opts(ctx), [:context])
             ) do
        {:ok, Support.query_detail(query)}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end
  end
end
