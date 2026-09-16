defmodule Lotus.SQL.Sanitizer do
  @moduledoc """
  Shared helpers for cleaning SQL strings before further processing.
  """

  @doc """
  Strips a trailing semicolon (and surrounding whitespace) from a SQL string.

  This is used by injectors that wrap queries in CTEs, where an embedded
  trailing semicolon would be misdetected as a multi-statement query.
  """
  @spec strip_trailing_semicolon(String.t()) :: String.t()
  def strip_trailing_semicolon(sql) do
    sql |> String.trim_trailing() |> String.trim_trailing(";") |> String.trim_trailing()
  end
end
