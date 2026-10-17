if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.UpdateQuery do
    @moduledoc false
    use Sake.Tool,
      name: "update_query",
      title: "Change a saved query",
      description:
        "Change a saved query's name, description, statement, data source or variables. " <>
          "Fields left out keep their values. Dashboards and charts that use the query " <>
          "show the change.",
      scope: "lotus:write",
      annotations: [read_only: false, destructive: true, idempotent: true, open_world: false]

    arg :id, :integer, required: true, description: "The saved query's id"
    arg :name, :string, max_length: 255, description: "A new name"
    arg :statement, :string, max_length: 100_000, description: "A new statement"
    arg :data_source, :string, description: "A new data source"
    arg :description, :string, max_length: 2000, description: "A new description"

    arg :variables, {:array, :any},
      description: "The variables, replacing the current ones (see save_query)"

    alias Lotus.MCP.Support

    @impl true
    def execute(%{id: id} = args, ctx) do
      with {:ok, query} <- Support.fetch_query(id),
           {:ok, attrs} <- attrs(args),
           :ok <-
             Support.read_only_statement(
               attrs[:statement] || query.statement,
               attrs[:data_source] || query.data_source || elem(Lotus.default_data_source(), 0)
             ),
           {:ok, query} <-
             Lotus.update_query(query, attrs, Keyword.take(Support.actor_opts(ctx), [:context])) do
        {:ok, Support.query_detail(query)}
      else
        {:error, reason} -> {:error, Support.error(reason)}
      end
    end

    # Sake passes an argument left out as nil: only those given change.
    defp attrs(args) do
      args = for {key, value} <- args, value != nil, into: %{}, do: {key, value}

      with {:ok, attrs} <- data_source(Map.take(args, [:name, :statement, :description]), args),
           {:ok, attrs} <- variables(attrs, args) do
        if attrs == %{}, do: {:error, "Nothing to change"}, else: {:ok, attrs}
      end
    end

    defp data_source(attrs, %{data_source: ds}) do
      with {:ok, ds} <- Support.data_source(ds), do: {:ok, Map.put(attrs, :data_source, ds)}
    end

    defp data_source(attrs, _args), do: {:ok, attrs}

    defp variables(attrs, %{variables: variables}) do
      with {:ok, variables} <- Support.variables(variables),
           do: {:ok, Map.put(attrs, :variables, variables)}
    end

    defp variables(attrs, _args), do: {:ok, attrs}
  end
end
