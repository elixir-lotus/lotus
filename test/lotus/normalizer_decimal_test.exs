defmodule Lotus.NormalizerDecimalTest do
  @moduledoc """
  A numeric column is the most ordinary thing a query can return, so
  normalizing a Decimal must not depend on which Decimal an application
  happened to resolve.
  """

  use ExUnit.Case, async: true

  test "the Decimal in use exports the arity the normalizer calls" do
    {:module, Decimal} = Code.ensure_loaded(Decimal)

    assert function_exported?(Decimal, :to_string, 3),
           """
           Decimal #{Application.spec(:decimal, :vsn)} has no to_string/3.
           Lotus.Normalizer needs it for `max_digits: :infinity`; the mix.exs
           requirement is what keeps an application off those versions.
           """
  end

  test "renders an ordinary decimal" do
    assert Lotus.Normalizer.normalize(Decimal.new("123.45")) == "123.45"
  end

  test "renders a numeric wider than Decimal's default output cap" do
    # An unconstrained Postgres numeric allows far more digits than Decimal
    # prints by default, which is why the normalizer passes max_digits.
    wide = Decimal.new(1, String.duplicate("9", 2_000) |> String.to_integer(), 0)

    rendered = Lotus.Normalizer.normalize(wide)

    assert is_binary(rendered)
    assert String.length(rendered) >= 2_000
  end

  test "renders the values a numeric column can also hold" do
    assert Lotus.Normalizer.normalize(Decimal.new("0")) == "0"
    assert Lotus.Normalizer.normalize(Decimal.new("-1.5")) == "-1.5"
  end
end
