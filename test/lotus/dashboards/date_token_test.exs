defmodule Lotus.Dashboards.DateTokenTest do
  use ExUnit.Case, async: true

  alias Lotus.Dashboards.DateToken

  doctest DateToken

  @monday ~D[2026-09-14]

  @ranges_on_monday [
    {"today", ~D[2026-09-14], ~D[2026-09-14]},
    {"yesterday", ~D[2026-09-13], ~D[2026-09-13]},
    {"last_7_days", ~D[2026-09-08], ~D[2026-09-14]},
    {"last_30_days", ~D[2026-08-16], ~D[2026-09-14]},
    {"last_90_days", ~D[2026-06-17], ~D[2026-09-14]},
    {"this_week", ~D[2026-09-14], ~D[2026-09-20]},
    {"this_month", ~D[2026-09-01], ~D[2026-09-30]},
    {"this_quarter", ~D[2026-07-01], ~D[2026-09-30]},
    {"this_year", ~D[2026-01-01], ~D[2026-12-31]},
    {"last_week", ~D[2026-09-07], ~D[2026-09-13]},
    {"last_month", ~D[2026-08-01], ~D[2026-08-31]},
    {"last_quarter", ~D[2026-04-01], ~D[2026-06-30]},
    {"last_year", ~D[2025-01-01], ~D[2025-12-31]}
  ]

  describe "tokens/0" do
    test "lists every token" do
      assert DateToken.tokens() == Enum.map(@ranges_on_monday, &elem(&1, 0))
    end
  end

  describe "single_day?/1" do
    test "is true for today and yesterday" do
      assert DateToken.single_day?("today")
      assert DateToken.single_day?("yesterday")
    end

    test "is false for range tokens and other values" do
      refute DateToken.single_day?("last_7_days")
      refute DateToken.single_day?("this_month")
      refute DateToken.single_day?("2026-09-14")
      refute DateToken.single_day?(nil)
    end
  end

  describe "range/2" do
    for {token, first, last} <- @ranges_on_monday do
      test "resolves #{token} on 2026-09-14" do
        assert DateToken.range(unquote(token), @monday) ==
                 {:ok, Date.range(unquote(Macro.escape(first)), unquote(Macro.escape(last)))}
      end
    end

    test "resolves last_month from the last day of a longer month" do
      assert DateToken.range("last_month", ~D[2026-03-31]) ==
               {:ok, Date.range(~D[2026-02-01], ~D[2026-02-28])}
    end

    test "ends February on the 29th in a leap year" do
      assert DateToken.range("this_month", ~D[2024-02-10]) ==
               {:ok, Date.range(~D[2024-02-01], ~D[2024-02-29])}

      assert DateToken.range("last_month", ~D[2024-03-31]) ==
               {:ok, Date.range(~D[2024-02-01], ~D[2024-02-29])}
    end

    test "resolves last_quarter in the first quarter to the previous year" do
      assert DateToken.range("last_quarter", ~D[2026-02-10]) ==
               {:ok, Date.range(~D[2025-10-01], ~D[2025-12-31])}
    end

    test "resolves this_quarter on the last day of the year" do
      assert DateToken.range("this_quarter", ~D[2026-12-31]) ==
               {:ok, Date.range(~D[2026-10-01], ~D[2026-12-31])}
    end

    test "resolves weeks that cross the year end" do
      assert DateToken.range("this_week", ~D[2026-01-01]) ==
               {:ok, Date.range(~D[2025-12-29], ~D[2026-01-04])}

      assert DateToken.range("last_week", ~D[2026-01-01]) ==
               {:ok, Date.range(~D[2025-12-22], ~D[2025-12-28])}
    end

    test "resolves years from the last day of a leap year" do
      assert DateToken.range("this_year", ~D[2024-12-31]) ==
               {:ok, Date.range(~D[2024-01-01], ~D[2024-12-31])}

      assert DateToken.range("last_year", ~D[2024-12-31]) ==
               {:ok, Date.range(~D[2023-01-01], ~D[2023-12-31])}
    end

    test "resolves last_90_days across a year end" do
      assert DateToken.range("last_90_days", ~D[2026-03-01]) ==
               {:ok, Date.range(~D[2025-12-02], ~D[2026-03-01])}
    end

    test "returns :error for a value that is not a token" do
      assert DateToken.range("next_week", @monday) == :error
      assert DateToken.range("2026-09-14", @monday) == :error
      assert DateToken.range(nil, @monday) == :error
    end
  end

  describe "resolve/3 for a :date_range filter" do
    for {token, first, last} <- @ranges_on_monday do
      test "resolves #{token} to a comma-separated range" do
        expected =
          Date.to_iso8601(unquote(Macro.escape(first))) <>
            "," <> Date.to_iso8601(unquote(Macro.escape(last)))

        assert DateToken.resolve(unquote(token), :date_range, @monday) == expected
      end
    end

    test "keeps a concrete range" do
      assert DateToken.resolve("2026-01-01,2026-01-31", :date_range, @monday) ==
               "2026-01-01,2026-01-31"
    end
  end

  describe "resolve/3 for a :date filter" do
    test "resolves today and yesterday to one date" do
      assert DateToken.resolve("today", :date, @monday) == "2026-09-14"
      assert DateToken.resolve("yesterday", :date, @monday) == "2026-09-13"
    end

    test "keeps a range token" do
      assert DateToken.resolve("last_7_days", :date, @monday) == "last_7_days"
      assert DateToken.resolve("this_month", :date, @monday) == "this_month"
    end

    test "keeps a concrete date" do
      assert DateToken.resolve("2026-01-01", :date, @monday) == "2026-01-01"
    end
  end

  describe "resolve/3 for other filter types" do
    test "keeps tokens unchanged" do
      for filter_type <- [:text, :number, :select] do
        assert DateToken.resolve("today", filter_type, @monday) == "today"
        assert DateToken.resolve("last_7_days", filter_type, @monday) == "last_7_days"
      end
    end
  end

  describe "resolve/3 with values that are not tokens" do
    test "keeps them unchanged" do
      assert DateToken.resolve("next_week", :date_range, @monday) == "next_week"
      assert DateToken.resolve(nil, :date_range, @monday) == nil
      assert DateToken.resolve(nil, :date, @monday) == nil
    end
  end
end
