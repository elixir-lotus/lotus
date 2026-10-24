defmodule Lotus.Delivery.Formats.Filename do
  @moduledoc false

  # File names for attachments: lowercase words joined by underscores.

  @doc "A file name base for `title`."
  def slug(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "result"
      slug -> String.slice(slug, 0, 80)
    end
  end

  @doc "Each result with a file name base no other result has."
  def unique(results) do
    {named, _seen} =
      Enum.map_reduce(results, %{}, fn %{title: title} = result, seen ->
        base = slug(title)
        count = Map.get(seen, base, 0) + 1
        name = if count == 1, do: base, else: "#{base}_#{count}"
        {{name, result}, Map.put(seen, base, count)}
      end)

    named
  end
end
