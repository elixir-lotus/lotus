defmodule Lotus.ExportFormulaTest do
  # With `csv_escape_formulas: true`, a text cell a spreadsheet would run as
  # a formula is written with a leading `'`.
  use ExUnit.Case, async: true
  use Mimic

  alias Lotus.{Export, Result}

  @result Result.new(["=name", "n"], [
            ["=1+1", -1],
            ["@cmd", 2],
            ["+x", 3],
            ["-y", 4],
            ["plain", 5]
          ])

  defp csv, do: @result |> Export.to_csv() |> IO.iodata_to_binary()

  test "is off by default: cells are written as they are" do
    assert csv() == "=name,n\n=1+1,-1\n@cmd,2\n+x,3\n-y,4\nplain,5\n"
  end

  test "escapes text cells, the header too, and leaves numbers alone" do
    stub(Lotus.Config, :csv_escape_formulas?, fn -> true end)

    assert csv() == "'=name,n\n'=1+1,-1\n'@cmd,2\n'+x,3\n'-y,4\nplain,5\n"
  end
end
