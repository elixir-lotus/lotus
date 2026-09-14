defmodule Lotus.Dashboards.DateToken do
  @moduledoc """
  Resolves relative date tokens in dashboard filter values.

  A dashboard filter value, the `default_value` of a filter or a value in
  `:filter_values`, can be a token such as `"last_30_days"` in place of a
  concrete date. `Lotus.Dashboards` resolves the token each time a card runs,
  so a dashboard shows current data without stored dates.

  ## Tokens

  The ranges below are for a run on Monday 2026-09-14.

  | Token | Range |
  |-------|-------|
  | `"today"` | 2026-09-14 to 2026-09-14 |
  | `"yesterday"` | 2026-09-13 to 2026-09-13 |
  | `"last_7_days"` | 2026-09-08 to 2026-09-14 |
  | `"last_30_days"` | 2026-08-16 to 2026-09-14 |
  | `"last_90_days"` | 2026-06-17 to 2026-09-14 |
  | `"this_week"` | 2026-09-14 to 2026-09-20 |
  | `"this_month"` | 2026-09-01 to 2026-09-30 |
  | `"this_quarter"` | 2026-07-01 to 2026-09-30 |
  | `"this_year"` | 2026-01-01 to 2026-12-31 |
  | `"last_week"` | 2026-09-07 to 2026-09-13 |
  | `"last_month"` | 2026-08-01 to 2026-08-31 |
  | `"last_quarter"` | 2026-04-01 to 2026-06-30 |
  | `"last_year"` | 2025-01-01 to 2025-12-31 |

  The `last_N_days` tokens include today. The week, month, quarter and year
  tokens cover the full calendar period, also the days after today. Weeks are
  ISO weeks and start on Monday. Today is `Date.utc_today/0` unless the caller
  gives a date.

  ## Resolution by filter type

  - `:date_range` - every token becomes `"YYYY-MM-DD,YYYY-MM-DD"`, the value
    that the `date_range_start` and `date_range_end` transforms split
  - `:date` - `"today"` and `"yesterday"` become `"YYYY-MM-DD"`. A range token
    stays unchanged, and `Lotus.Storage.DashboardFilter` does not accept one as
    the `default_value`
  - `:text`, `:number` and `:select` - the value stays unchanged

  A value that is not a token, a concrete date for example, stays unchanged.
  """

  @tokens ~w(today yesterday last_7_days last_30_days last_90_days this_week this_month this_quarter this_year last_week last_month last_quarter last_year)
  @single_day_tokens ~w(today yesterday)

  @type token :: String.t()
  @type filter_type :: :text | :number | :date | :date_range | :select

  @doc """
  Returns all tokens.

  ## Examples

      iex> "last_30_days" in Lotus.Dashboards.DateToken.tokens()
      true
  """
  @spec tokens() :: [token()]
  def tokens, do: @tokens

  @doc """
  Returns `true` when `value` is a token for one day, `"today"` or
  `"yesterday"`.

  ## Examples

      iex> Lotus.Dashboards.DateToken.single_day?("yesterday")
      true

      iex> Lotus.Dashboards.DateToken.single_day?("last_7_days")
      false
  """
  @spec single_day?(term()) :: boolean()
  def single_day?(value), do: value in @single_day_tokens

  @doc """
  Returns the date range of `token` relative to `today`.

  Returns `:error` when `token` is not a token.

  ## Examples

      iex> Lotus.Dashboards.DateToken.range("last_quarter", ~D[2026-09-14])
      {:ok, Date.range(~D[2026-04-01], ~D[2026-06-30])}

      iex> Lotus.Dashboards.DateToken.range("2026-09-14", ~D[2026-09-14])
      :error
  """
  @spec range(term(), Date.t()) :: {:ok, Date.Range.t()} | :error
  def range(token, today \\ Date.utc_today())

  def range("today", today), do: {:ok, Date.range(today, today)}
  def range("yesterday", today), do: {:ok, today |> Date.add(-1) |> then(&Date.range(&1, &1))}
  def range("last_7_days", today), do: {:ok, days_ending_on(today, 7)}
  def range("last_30_days", today), do: {:ok, days_ending_on(today, 30)}
  def range("last_90_days", today), do: {:ok, days_ending_on(today, 90)}
  def range("this_week", today), do: {:ok, week_of(today)}
  def range("this_month", today), do: {:ok, month_of(today)}
  def range("this_quarter", today), do: {:ok, quarter_of(today)}
  def range("this_year", today), do: {:ok, year_of(today)}
  def range("last_week", today), do: {:ok, today |> Date.add(-7) |> week_of()}

  def range("last_month", today),
    do: {:ok, today |> Date.beginning_of_month() |> Date.add(-1) |> month_of()}

  def range("last_quarter", today),
    do: {:ok, today |> quarter_start() |> Date.add(-1) |> quarter_of()}

  def range("last_year", today), do: {:ok, today |> Date.shift(year: -1) |> year_of()}
  def range(_value, _today), do: :error

  @doc """
  Resolves `value` for a filter of `filter_type` relative to `today`.

  See the "Resolution by filter type" section of this module for the rules.

  ## Examples

      iex> Lotus.Dashboards.DateToken.resolve("last_7_days", :date_range, ~D[2026-09-14])
      "2026-09-08,2026-09-14"

      iex> Lotus.Dashboards.DateToken.resolve("today", :date, ~D[2026-09-14])
      "2026-09-14"

      iex> Lotus.Dashboards.DateToken.resolve("today", :text, ~D[2026-09-14])
      "today"
  """
  @spec resolve(term(), filter_type(), Date.t()) :: term()
  def resolve(value, filter_type, today \\ Date.utc_today())

  def resolve(value, :date_range, today) when value in @tokens do
    {:ok, range} = range(value, today)
    Date.to_iso8601(range.first) <> "," <> Date.to_iso8601(range.last)
  end

  def resolve(value, :date, today) when value in @single_day_tokens do
    {:ok, range} = range(value, today)
    Date.to_iso8601(range.first)
  end

  def resolve(value, _filter_type, _today), do: value

  defp days_ending_on(last, count), do: Date.range(Date.add(last, 1 - count), last)

  defp week_of(date) do
    Date.range(Date.beginning_of_week(date, :monday), Date.end_of_week(date, :monday))
  end

  defp month_of(date), do: Date.range(Date.beginning_of_month(date), Date.end_of_month(date))

  defp quarter_of(date) do
    first = quarter_start(date)
    last = first |> Date.shift(month: 2) |> Date.end_of_month()
    Date.range(first, last)
  end

  defp quarter_start(date) do
    Date.new!(date.year, (Date.quarter_of_year(date) - 1) * 3 + 1, 1, date.calendar)
  end

  defp year_of(date) do
    Date.range(
      Date.new!(date.year, 1, 1, date.calendar),
      Date.new!(date.year, 12, 31, date.calendar)
    )
  end
end
