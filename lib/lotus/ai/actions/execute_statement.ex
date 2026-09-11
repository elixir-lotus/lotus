defmodule Lotus.AI.Actions.ExecuteStatement do
  @moduledoc """
  Executes a query statement against a data source.

  Used by the investigation agent to run queries and analyze results.
  Returns column names, row count, and a preview of the first rows
  (capped to avoid overwhelming the LLM context).
  """

  @behaviour Lotus.AI.Action

  import Lotus.AI.Action, only: [actor_opts: 1]

  @max_preview_rows 50

  @impl true
  def name, do: "execute_statement"

  @impl true
  def description,
    do:
      "Execute a read-only query statement against a data source and return the " <>
        "results. Provide a short label describing the purpose of this query step."

  @impl true
  def schema do
    [
      sql: [type: :string, required: true, doc: "The query statement to execute"],
      data_source: [
        type: :string,
        required: true,
        doc: "Name of the data source to run against"
      ],
      label: [
        type: :string,
        required: true,
        doc: "Short description of what this query investigates (e.g., 'Check revenue by region')"
      ]
    ]
  end

  @impl true
  def run(params, context) do
    started_at = DateTime.utc_now()

    opts =
      [repo: params.data_source, read_only: true] ++ actor_opts(context)

    case Lotus.run_statement(params.sql, [], opts) do
      {:ok, result} ->
        preview_rows =
          result.rows
          |> Enum.take(@max_preview_rows)
          |> Enum.map(fn row -> Enum.map(row, &Lotus.Normalizer.normalize/1) end)

        {:ok,
         %{
           label: params.label,
           sql: params.sql,
           data_source: params.data_source,
           columns: result.columns,
           rows: preview_rows,
           num_rows: result.num_rows,
           duration_ms: result.duration_ms,
           truncated: (result.num_rows || 0) > @max_preview_rows,
           started_at: started_at,
           completed_at: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:ok,
         %{
           label: params.label,
           sql: params.sql,
           data_source: params.data_source,
           error: format_error(reason),
           started_at: started_at,
           completed_at: DateTime.utc_now()
         }}
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
