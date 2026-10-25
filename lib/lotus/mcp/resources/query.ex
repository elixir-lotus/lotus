if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Resources.Query do
    @moduledoc false
    use Sake.Resource,
      uri: "lotus://queries/{id}",
      name: "query",
      title: "Saved query",
      description: "A saved query: its statement, variables and charts.",
      mime_type: "application/json",
      scope: "lotus:read"

    alias Lotus.MCP.Support

    @impl true
    def read(%{id: id}, ctx) do
      with {id, ""} <- Integer.parse(id),
           {:ok, query} <- Support.fetch_query(id, ctx) do
        {:ok, Support.query_detail(query)}
      else
        _ -> {:error, :not_found}
      end
    end

    @impl true
    def list(ctx) do
      Lotus.list_queries(Support.actor_opts(ctx))
      |> Enum.filter(&Support.exposed?/1)
      |> Enum.take(Support.list_limit())
      |> Enum.map(fn query ->
        %{uri: "lotus://queries/#{query.id}", name: query.name, description: query.description}
      end)
    end
  end
end
