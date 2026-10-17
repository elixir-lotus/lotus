defmodule Lotus.AI.Actions.ListDataSources do
  @moduledoc """
  Lists all available data sources (repositories).

  Lets the investigation agent discover which databases are available
  for cross-database investigations.
  """

  @behaviour Lotus.AI.Action

  @impl true
  def name, do: "list_data_sources"

  @impl true
  def description,
    do:
      "List all available data sources (database connections) that can be queried, " <>
        "with what each holds where it is described. " <>
        "Use this to discover which databases are available for investigation."

  @impl true
  def schema, do: []

  @impl true
  def run(_params, _context) do
    names = Lotus.list_data_source_names()

    sources =
      Enum.map(names, fn name ->
        source_type = Lotus.Source.source_type(name)

        case Lotus.data_source_description(name) do
          nil -> %{name: name, type: source_type}
          description -> %{name: name, type: source_type, description: description}
        end
      end)

    {:ok, %{data_sources: sources}}
  end
end
