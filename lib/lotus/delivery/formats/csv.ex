defmodule Lotus.Delivery.Formats.CSV do
  @moduledoc """
  The `"csv"` format: one CSV file per result, header first, as
  `Lotus.Export.to_csv/1` writes it. A dashboard gives a file per query card.
  """

  @behaviour Lotus.Delivery.Format

  alias Lotus.Delivery.Formats.Filename

  @impl true
  def render(%{results: results}) do
    attachments =
      results
      |> Filename.unique()
      |> Enum.map(fn {name, %{result: result}} ->
        %{filename: name <> ".csv", content_type: "text/csv", body: Lotus.Export.to_csv(result)}
      end)

    {:ok, attachments}
  end
end
