if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Tools.ListDataSources do
    @moduledoc false
    use Sake.Tool,
      name: "list_data_sources",
      title: "List data sources",
      description:
        "List the data sources (databases) that can be queried, with each one's type, " <>
          "what it holds where it is described, and which is the default.",
      scope: "lotus:read",
      annotations: [read_only: true, idempotent: true, open_world: false]

    alias Lotus.MCP.Support

    @impl true
    def execute(_args, _ctx) do
      {default, _} = Lotus.default_data_source()

      sources =
        Enum.map(Support.data_source_names(), fn name ->
          %{name: name, type: Lotus.Source.source_type(name), default: name == default}
          |> put_description(Lotus.data_source_description(name))
        end)

      {:ok, %{data_sources: sources}}
    end

    defp put_description(source, nil), do: source
    defp put_description(source, description), do: Map.put(source, :description, description)
  end
end
