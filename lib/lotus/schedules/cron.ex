defmodule Lotus.Schedules.Cron do
  @moduledoc """
  Cron expressions in a time zone: when a schedule runs next.

  An expression is the standard five fields (`minute hour day month weekday`),
  read as the wall clock of the schedule's time zone, so `"0 8 * * MON"` in
  `"Europe/Lisbon"` runs at 08:00 Lisbon time all year: 07:00 UTC in summer,
  08:00 UTC in winter. The next run is computed for each run with that day's
  offset, so a schedule follows daylight saving.

  On the two days a year the clock changes:

    * a time the clock skips (01:30 when it jumps from 01:00 to 02:00) runs at
      the first moment after the gap;
    * a time the clock repeats (01:30 twice when it falls back) runs once, at
      its first occurrence.

  The time zone rules come from `database/0`.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @doc """
  Parses `expression`. `{:error, message}` for one that is not five valid
  cron fields.
  """
  @spec parse(String.t()) :: {:ok, Crontab.CronExpression.t()} | {:error, String.t()}
  def parse(expression) when is_binary(expression) do
    case String.split(expression) do
      fields when length(fields) == 5 -> Parser.parse(expression)
      _fields -> {:error, "must have five fields: minute hour day month weekday"}
    end
  end

  def parse(_expression), do: {:error, "must be a string"}

  @doc "Whether `time_zone` is a time zone `database/0` knows."
  @spec valid_time_zone?(String.t()) :: boolean()
  def valid_time_zone?(time_zone) when is_binary(time_zone),
    do: match?({:ok, _}, DateTime.now(time_zone, database()))

  def valid_time_zone?(_time_zone), do: false

  @doc """
  The first time strictly after `from` that `expression` matches in
  `time_zone`, as a UTC `DateTime`. Minutes are the smallest step: `from`
  counts as the start of its minute.
  """
  @spec next_run(Crontab.CronExpression.t() | String.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_run(expression, time_zone, %DateTime{} = from) when is_binary(expression) do
    with {:ok, parsed} <- parse(expression), do: next_run(parsed, time_zone, from)
  end

  def next_run(%Crontab.CronExpression{} = expression, time_zone, %DateTime{} = from) do
    db = database()

    with {:ok, local} <- DateTime.shift_zone(from, time_zone, db) do
      start =
        local
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)
        |> Map.put(:second, 0)
        |> NaiveDateTime.add(60)

      search(expression, time_zone, db, from, start)
    end
  end

  # During the hour the clock repeats, a wall clock time maps to its first
  # occurrence, which can be before `from`; the search goes on from the next
  # minute, so a run is never due again as soon as it ran.
  defp search(expression, time_zone, db, from, start) do
    with {:ok, naive} <- Scheduler.get_next_run_date(expression, start),
         {:ok, at} <- from_wall_clock(naive, time_zone, db) do
      utc = at |> DateTime.shift_zone!("Etc/UTC", db) |> Map.put(:microsecond, {0, 6})

      if DateTime.compare(utc, from) == :gt,
        do: {:ok, utc},
        else: search(expression, time_zone, db, from, NaiveDateTime.add(naive, 60))
    end
  end

  # The skipped and the repeated wall clock times of a daylight saving change.
  defp from_wall_clock(naive, time_zone, db) do
    case DateTime.from_naive(naive, time_zone, db) do
      {:ok, at} -> {:ok, at}
      {:gap, _just_before, just_after} -> {:ok, just_after}
      {:ambiguous, first, _second} -> {:ok, first}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The time zone database schedules use: the `:time_zone_database` of the
  `:scheduler` config, else the one the application configures, else
  the database of the `tz` package. Lotus passes it to each call and never sets the
  global one.
  """
  @spec database() :: module()
  def database do
    case Keyword.get(Lotus.Config.scheduler(), :time_zone_database) do
      nil ->
        case Calendar.get_time_zone_database() do
          Calendar.UTCOnlyTimeZoneDatabase -> Tz.TimeZoneDatabase
          configured -> configured
        end

      configured ->
        configured
    end
  end
end
