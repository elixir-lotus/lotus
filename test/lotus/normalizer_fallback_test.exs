defmodule Lotus.NormalizerFallbackTest do
  @moduledoc """
  A query can return a value of any type a driver or extension decodes to,
  so normalizing one Lotus has no impl for must not raise.
  """

  use ExUnit.Case, async: true

  alias Lotus.Normalizer

  defmodule Unknown do
    defstruct [:value]
  end

  describe "a struct without an impl" do
    test "falls back to inspect/1" do
      value = %Unknown{value: 1}

      assert Normalizer.normalize(value) == inspect(value)
    end

    test "falls back inside a list" do
      value = %Unknown{value: 1}

      assert Normalizer.normalize([value]) == [inspect(value)]
    end
  end

  describe "Postgrex types" do
    test "renders a macaddr as PostgreSQL does" do
      mac = %Postgrex.MACADDR{address: {8, 0, 43, 1, 2, 3}}

      assert Normalizer.normalize(mac) == "08:00:2b:01:02:03"
    end

    test "renders a line as {a,b,c}" do
      assert Normalizer.normalize(%Postgrex.Line{a: 1.0, b: -1.0, c: 0.0}) == "{1.0,-1.0,0.0}"
    end

    test "renders each lexeme of a tsvector" do
      tsvector = [
        %Postgrex.Lexeme{word: "cat", positions: [{3, nil}]},
        %Postgrex.Lexeme{word: "fat", positions: [{2, :A}, {4, nil}]},
        %Postgrex.Lexeme{word: "it's", positions: []}
      ]

      assert Normalizer.normalize(tsvector) == ["'cat':3", "'fat':2A,4", "'it''s'"]
    end

    test "renders a multirange as a set of ranges" do
      multirange = %Postgrex.Multirange{
        ranges: [
          %Postgrex.Range{lower: 1, upper: 3, lower_inclusive: true, upper_inclusive: false},
          %Postgrex.Range{lower: 5, upper: 7, lower_inclusive: true, upper_inclusive: false}
        ]
      }

      assert Normalizer.normalize(multirange) == "{[1,3),[5,7)}"
      assert Normalizer.normalize(%Postgrex.Multirange{ranges: []}) == "{}"
    end
  end
end
