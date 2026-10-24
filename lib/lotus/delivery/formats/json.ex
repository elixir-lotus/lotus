defmodule Lotus.Delivery.Formats.JSON do
  @moduledoc """
  The `"json"` format: one JSON file with the title and every result, each
  with its title, columns and rows (values as `Lotus.Value.for_json/1` gives
  them):

      {"title": "Weekly revenue",
       "results": [{"title": "Revenue", "columns": ["region", "total"], "rows": [["north", 120]]}]}
  """

  @behaviour Lotus.Delivery.Format

  alias Lotus.Delivery.Formats.Filename

  @impl true
  def render(%{title: title, results: results}) do
    body = %{
      "title" => title,
      "results" =>
        Enum.map(results, fn %{title: result_title, result: result} ->
          %{
            "title" => result_title,
            "columns" => result.columns,
            "rows" => Enum.map(result.rows, fn row -> Enum.map(row, &Lotus.Value.for_json/1) end)
          }
        end)
    }

    {:ok,
     [
       %{
         filename: Filename.slug(title) <> ".json",
         content_type: "application/json",
         body: Lotus.JSON.encode!(body)
       }
     ]}
  end
end
