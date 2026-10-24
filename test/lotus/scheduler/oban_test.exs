defmodule Lotus.Scheduler.ObanTest do
  @moduledoc """
  With `executor: Lotus.Scheduler.Oban`, a claimed run becomes a
  `Lotus.Scheduler.Oban.RunWorker` job, and the tick is a job Oban's cron
  plugin runs.
  """
  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Config, Schedules}
  alias Lotus.Scheduler.Oban.{RunWorker, TickWorker}
  alias Lotus.Storage.{Schedule, ScheduleRun}

  @oban Lotus.Scheduler.ObanTest.Oban

  setup do
    start_supervised!({Oban, name: @oban, repo: Lotus.Test.Repo, testing: :inline})

    stub(Config, :scheduler, fn ->
      [executor: Lotus.Scheduler.Oban, oban: [name: @oban, queue: :lotus]]
    end)

    query = query_fixture(%{statement: "SELECT 1 AS one"})

    {:ok, schedule} =
      Schedules.create_schedule(%{name: "Hourly", query_id: query.id, cron: "0 * * * *"})

    Repo.update_all(from(s in Schedule, where: s.id == ^schedule.id),
      set: [next_run_at: DateTime.add(DateTime.utc_now(), -60)]
    )

    %{schedule: schedule}
  end

  test "the tick job claims the due run and Oban performs it", %{schedule: schedule} do
    assert :ok = TickWorker.perform(%Oban.Job{args: %{}})
    assert [%ScheduleRun{status: "succeeded", row_count: 1}] = Schedules.list_runs(schedule)
  end

  test "a failed run is an error for Oban to retry, and a retry takes it again", %{
    schedule: schedule
  } do
    broken = query_fixture(%{statement: "SELECT * FROM no_such_table"})
    {:ok, schedule} = Schedules.update_schedule(schedule, %{query_id: broken.id})

    {:ok, run} =
      schedule.id |> ScheduleRun.claim_changeset(~U[2026-10-24 03:00:00.000000Z]) |> Repo.insert()

    assert {:error, error} = RunWorker.perform(%Oban.Job{args: %{"run_id" => run.id}, attempt: 1})
    assert error =~ "no_such_table"

    assert {:error, _} = RunWorker.perform(%Oban.Job{args: %{"run_id" => run.id}, attempt: 2})
    assert :ok = RunWorker.perform(%Oban.Job{args: %{"run_id" => run.id}, attempt: 1})

    assert {:cancel, :not_found} =
             RunWorker.perform(%Oban.Job{args: %{"run_id" => -1}, attempt: 1})
  end

  test "the run job goes to the configured queue, unique per run" do
    job = RunWorker.new(%{"run_id" => 7}, queue: :lotus)
    assert job.changes.queue == "lotus"
    assert %{keys: [:run_id]} = job.changes.unique
  end
end
