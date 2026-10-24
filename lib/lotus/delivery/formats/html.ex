defmodule Lotus.Delivery.Formats.HTML do
  @moduledoc """
  The `"html"` format: one HTML document with the title and a table per
  result, for the body of an email or a page. Every value is escaped.
  """

  @behaviour Lotus.Delivery.Format

  alias Lotus.Delivery.Formats.Filename

  @impl true
  def render(%{title: title, results: results}) do
    body = [
      "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>",
      escape(title),
      "</title></head><body>\n<h1>",
      escape(title),
      "</h1>\n",
      Enum.map(results, &table/1),
      "</body></html>\n"
    ]

    {:ok, [%{filename: Filename.slug(title) <> ".html", content_type: "text/html", body: body}]}
  end

  defp table(%{title: title, result: result}) do
    [
      "<h2>",
      escape(title),
      "</h2>\n<table>\n<thead><tr>",
      Enum.map(result.columns, &["<th>", escape(&1), "</th>"]),
      "</tr></thead>\n<tbody>\n",
      Enum.map(result.rows, fn row ->
        [
          "<tr>",
          Enum.map(row, &["<td>", escape(Lotus.Value.to_display_string(&1)), "</td>"]),
          "</tr>\n"
        ]
      end),
      "</tbody>\n</table>\n"
    ]
  end

  @doc false
  def escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
