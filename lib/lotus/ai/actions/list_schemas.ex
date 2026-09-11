defmodule Lotus.AI.Actions.ListSchemas do
  @moduledoc """
  Lists all available database schemas.

  Used as an LLM tool so the agent can discover schemas like
  "public", "reporting", "analytics" before querying tables.
  """

  @behaviour Lotus.AI.Action

  import Lotus.AI.Action, only: [actor_opts: 1]

  @impl true
  def name, do: "list_schemas"

  @impl true
  def description,
    do: "Get list of all available schemas in the database (e.g., 'public', 'reporting')"

  @impl true
  def schema do
    [
      data_source: [type: :string, required: true, doc: "Name of the data source to query"]
    ]
  end

  @impl true
  def run(params, context) do
    case Lotus.Schema.list_schemas(params.data_source, actor_opts(context)) do
      {:ok, schemas} ->
        {:ok, %{schemas: schemas}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
