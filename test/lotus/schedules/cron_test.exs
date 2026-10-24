defmodule Lotus.Schedules.CronTest do
  @moduledoc """
  Cron expressions read as the wall clock of a time zone, through daylight
  saving: Lisbon moves to summer time on 29 March 2026 (01:00 -> 02:00) and
  back on 25 October 2026 (02:00 -> 01:00).
  """
  use ExUnit.Case, async: true

  alias Lotus.Schedules.Cron

  defp next!(cron, zone, from) do
    {:ok, at} = Cron.next_run(cron, zone, from)
    at
  end

  describe "parse/1" do
    test "five fields" do
      assert {:ok, _} = Cron.parse("0 8 * * MON")
      assert {:error, _} = Cron.parse("0 0 8 * * MON")
      assert {:error, _} = Cron.parse("every monday")
      assert {:error, _} = Cron.parse("61 8 * * *")
      assert {:error, _} = Cron.parse(nil)
    end
  end

  describe "next_run/3" do
    test "in UTC" do
      assert next!("0 8 * * MON", "Etc/UTC", ~U[2026-10-24 10:00:00Z]) ==
               ~U[2026-10-26 08:00:00.000000Z]
    end

    test "strictly after: a run at 08:00 is not due again at 08:00" do
      assert next!("0 8 * * *", "Etc/UTC", ~U[2026-10-24 08:00:00Z]) ==
               ~U[2026-10-25 08:00:00.000000Z]

      assert next!("0 8 * * *", "Etc/UTC", ~U[2026-10-24 07:59:30Z]) ==
               ~U[2026-10-24 08:00:00.000000Z]
    end

    test "08:00 in Lisbon is 07:00 UTC in summer and 08:00 UTC in winter" do
      assert next!("0 8 * * *", "Europe/Lisbon", ~U[2026-10-23 12:00:00Z]) ==
               ~U[2026-10-24 07:00:00.000000Z]

      assert next!("0 8 * * *", "Europe/Lisbon", ~U[2026-10-25 12:00:00Z]) ==
               ~U[2026-10-26 08:00:00.000000Z]
    end

    test "a time the clock skips runs at the first moment after the gap" do
      # 01:30 does not exist in Lisbon on 29 March: 02:00 WEST is 01:00 UTC.
      assert next!("30 1 * * *", "Europe/Lisbon", ~U[2026-03-28 12:00:00Z]) ==
               ~U[2026-03-29 01:00:00.000000Z]
    end

    test "a time the clock repeats runs once, at its first occurrence" do
      # 01:30 happens twice in Lisbon on 25 October: first at 00:30 UTC.
      first = next!("30 1 * * *", "Europe/Lisbon", ~U[2026-10-24 12:00:00Z])
      assert first == ~U[2026-10-25 00:30:00.000000Z]
      assert next!("30 1 * * *", "Europe/Lisbon", first) == ~U[2026-10-26 01:30:00.000000Z]
    end

    test "every run is later than the one before, through the repeated hour" do
      runs =
        Stream.iterate(~U[2026-10-24 23:00:00Z], &next!("*/15 * * * *", "Europe/Lisbon", &1))
        |> Enum.take(20)

      assert runs == Enum.sort(runs, DateTime)
      assert runs == Enum.uniq(runs)
    end

    test "an unknown time zone is an error" do
      assert {:error, _} =
               Cron.next_run("0 8 * * *", "Mars/Olympus_Mons", ~U[2026-10-24 10:00:00Z])

      refute Cron.valid_time_zone?("Mars/Olympus_Mons")
      assert Cron.valid_time_zone?("America/New_York")
    end
  end

  test "the database is Tz when the application configures none, without setting it" do
    assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
    assert Cron.database() == Tz.TimeZoneDatabase
    assert Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
  end
end
