defmodule Lotus.SchedulesTest do
  @moduledoc """
  Schedules (`Lotus.Schedules`), the claim that runs each slot once
  (`Lotus.Scheduler.tick/1`) and the run itself (`Lotus.Scheduler.Worker`).
  """
  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Config, Middleware, Scheduler, Schedules}
  alias Lotus.Scheduler.Worker
  alias Lotus.Storage.{Schedule, ScheduleRun}

  defmodule SendExecutor do
    @moduledoc false
    @behaviour Lotus.Scheduler.Executor
    def execute(run_id, _opts) do
      send(self(), {:execute, run_id})
      :ok
    end
  end

  defmodule PidExecutor do
    @moduledoc false
    @behaviour Lotus.Scheduler.Executor
    def execute(run_id, _opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:execute, run_id})
      :ok
    end
  end

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, event) do
      send(self(), {event, payload})
      {:cont, payload}
    end
  end

  defmodule Actor do
    @moduledoc false
    def ok(%Schedule{name: name}, tag),
      do: {:ok, context: %{schedule: name, tag: tag}, scope: :scheduled}

    def refuse(%Schedule{}), do: {:error, "no service account"}
  end

  defp scheduler(config) do
    stub(Config, :scheduler, fn -> config end)
  end

  defp schedule_fixture(attrs \\ %{}) do
    query = query_fixture(%{statement: "SELECT 1 AS one UNION ALL SELECT 2"})

    {:ok, schedule} =
      Schedules.create_schedule(
        Map.merge(%{name: "Nightly", query_id: query.id, cron: "0 3 * * *"}, attrs)
      )

    schedule
  end

  defp due!(schedule, at) do
    Repo.update_all(from(s in Schedule, where: s.id == ^schedule.id), set: [next_run_at: at])
    Schedules.get_schedule!(schedule.id)
  end

  setup do
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)
    :ok
  end

  describe "create_schedule/2 and update_schedule/3" do
    test "a schedule runs a query or a dashboard, with a valid cron and time zone" do
      query = query_fixture()

      assert {:error, cs} = Schedules.create_schedule(%{name: "x", cron: "0 8 * * *"})
      assert %{query_id: ["a query or a dashboard is required"]} = errors_on(cs)

      dashboard = dashboard_fixture()

      assert {:error, cs} =
               Schedules.create_schedule(%{
                 name: "x",
                 cron: "0 8 * * *",
                 query_id: query.id,
                 dashboard_id: dashboard.id
               })

      assert %{dashboard_id: [_]} = errors_on(cs)

      assert {:error, cs} =
               Schedules.create_schedule(%{name: "x", cron: "8 o'clock", query_id: query.id})

      assert %{cron: ["is not a cron expression: " <> _]} = errors_on(cs)

      assert {:error, cs} =
               Schedules.create_schedule(%{
                 name: "x",
                 cron: "0 8 * * *",
                 time_zone: "Mars/Base",
                 query_id: query.id
               })

      assert %{time_zone: ["is not a known time zone"]} = errors_on(cs)
    end

    test "a new schedule is due at its next run; a disabled one is never due" do
      schedule = schedule_fixture(%{cron: "0 8 * * *", time_zone: "Europe/Lisbon"})

      assert DateTime.compare(schedule.next_run_at, DateTime.utc_now()) == :gt

      assert %DateTime{hour: 8, minute: 0} =
               DateTime.shift_zone!(schedule.next_run_at, "Europe/Lisbon", Tz.TimeZoneDatabase)

      assert {:ok, %Schedule{next_run_at: nil}} =
               Schedules.update_schedule(schedule, %{enabled: false})
    end

    test "a new cron moves the next run; a new name does not" do
      schedule = schedule_fixture(%{cron: "0 8 * * *"})
      {:ok, renamed} = Schedules.update_schedule(schedule, %{name: "Renamed"})
      assert renamed.next_run_at == schedule.next_run_at

      {:ok, moved} = Schedules.update_schedule(schedule, %{cron: "30 9 * * *"})
      assert %DateTime{hour: 9, minute: 30} = moved.next_run_at
    end

    test "owner and tenant come from the options, and lists filter by them" do
      query = query_fixture()
      attrs = %{name: "A", query_id: query.id, cron: "0 8 * * *"}

      {:ok, a} = Schedules.create_schedule(attrs, tenant_id: "acme", owner_id: "42")
      {:ok, _b} = Schedules.create_schedule(%{attrs | name: "B"}, tenant_id: "globex")

      assert [%{id: id}] = Schedules.list_schedules(tenant_id: "acme")
      assert id == a.id
      assert [%{name: "A"}, %{name: "B"}] = Schedules.list_schedules(query_id: query.id)
      assert [%{name: "A"}, %{name: "B"}] = Schedules.list_schedules(enabled: true)
    end

    test "changes fire the content change events with resource :schedule" do
      Middleware.compile(%{after_content_change: [{CapturePlug, :after}]})
      schedule = schedule_fixture()
      assert_received {:after, %{op: :create, resource: :schedule}}

      {:ok, _} = Schedules.delete_schedule(schedule.id)
      assert_received {:after, %{op: :delete, resource: :schedule}}
      assert Schedules.get_schedule(schedule.id) == nil
    end
  end

  describe "tick/1" do
    setup do
      scheduler(executor: SendExecutor)
      :ok
    end

    test "claims a due run, hands it to the executor and moves the next run" do
      now = ~U[2026-10-24 12:00:00.000000Z]
      schedule = due!(schedule_fixture(), ~U[2026-10-24 03:00:00.000000Z])

      assert [run_id] = Scheduler.tick(now: now)
      assert_received {:execute, ^run_id}

      assert %ScheduleRun{status: "pending", scheduled_for: ~U[2026-10-24 03:00:00.000000Z]} =
               Repo.get!(ScheduleRun, run_id)

      assert Schedules.get_schedule!(schedule.id).next_run_at == ~U[2026-10-25 03:00:00.000000Z]
      assert Scheduler.tick(now: now) == []
    end

    test "a slot another node claimed is not run again" do
      now = ~U[2026-10-24 12:00:00.000000Z]
      schedule = due!(schedule_fixture(), ~U[2026-10-24 03:00:00.000000Z])
      assert [_run_id] = Scheduler.tick(now: now)
      assert_received {:execute, _}

      # The other node read the schedule before the first moved it.
      due!(schedule, ~U[2026-10-24 03:00:00.000000Z])

      assert Scheduler.tick(now: now) == []
      refute_received {:execute, _}
      assert [_one] = Schedules.list_runs(schedule)
    end

    test "missed slots run once, for the latest, then the schedule goes on" do
      now = ~U[2026-10-24 12:00:00.000000Z]
      schedule = due!(schedule_fixture(), ~U[2026-10-20 03:00:00.000000Z])

      assert [_run_id] = Scheduler.tick(now: now)
      assert Schedules.get_schedule!(schedule.id).next_run_at == ~U[2026-10-25 03:00:00.000000Z]
    end

    test "a disabled schedule, or one not yet due, is not run" do
      now = ~U[2026-10-24 12:00:00.000000Z]
      due!(schedule_fixture(), ~U[2026-10-24 13:00:00.000000Z])
      {:ok, disabled} = Schedules.update_schedule(schedule_fixture(), %{enabled: false})
      due!(disabled, ~U[2026-10-24 03:00:00.000000Z])

      assert Scheduler.tick(now: now) == []
    end
  end

  describe "Worker.perform/2" do
    defp claimed_run(schedule) do
      {:ok, run} =
        schedule.id
        |> ScheduleRun.claim_changeset(~U[2026-10-24 03:00:00.000000Z])
        |> Repo.insert()

      run
    end

    test "runs the query and records the rows" do
      scheduler([])
      schedule = schedule_fixture()
      run = claimed_run(schedule)

      assert {:ok, %ScheduleRun{status: "succeeded", row_count: 2, error: nil} = done} =
               Worker.perform(run.id)

      assert done.started_at && done.finished_at
      assert Schedules.get_schedule!(schedule.id).last_run_at == run.scheduled_for
      assert {:error, :not_pending} = Worker.perform(run.id)
    end

    test "a failed query is recorded as failed, and a retry takes it again" do
      scheduler([])
      query = query_fixture(%{statement: "SELECT * FROM no_such_table"})

      {:ok, schedule} =
        Schedules.create_schedule(%{name: "Broken", query_id: query.id, cron: "0 3 * * *"})

      run = claimed_run(schedule)

      assert {:ok, %ScheduleRun{status: "failed", error: error}} = Worker.perform(run.id)
      assert error =~ "no_such_table"
      assert {:error, :not_pending} = Worker.perform(run.id)
      assert {:ok, %ScheduleRun{status: "failed"}} = Worker.perform(run.id, retry: true)
    end

    test "a dashboard runs its query cards" do
      scheduler([])
      dashboard = dashboard_fixture()
      query = query_fixture(%{statement: "SELECT 1 AS one"})
      dashboard_card_fixture(dashboard, %{card_type: :query, query_id: query.id})
      dashboard_card_fixture(dashboard, %{card_type: :query, query_id: query.id, position: 1})

      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "Board",
          dashboard_id: dashboard.id,
          cron: "0 8 * * MON"
        })

      assert {:ok, %ScheduleRun{status: "succeeded", row_count: 2, details: %{"cards" => 2}}} =
               Worker.perform(claimed_run(schedule).id)
    end

    test "the actor callback gives the run its context and scope" do
      scheduler(actor: {Actor, :ok, [:nightly]})
      Middleware.compile(%{before_query: [{CapturePlug, :before_query}]})
      schedule = schedule_fixture()

      assert {:ok, %ScheduleRun{status: "succeeded"}} = Worker.perform(claimed_run(schedule).id)
      assert_received {:before_query, %{context: %{schedule: "Nightly", tag: :nightly}}}
    end

    test "without an actor callback a run has no context" do
      scheduler([])
      Middleware.compile(%{before_query: [{CapturePlug, :before_query}]})

      assert {:ok, _} = Worker.perform(claimed_run(schedule_fixture()).id)
      assert_received {:before_query, %{context: nil}}
    end

    test "an actor callback that refuses fails the run before anything runs" do
      scheduler(actor: {Actor, :refuse, []})
      Middleware.compile(%{before_query: [{CapturePlug, :before_query}]})

      assert {:ok, %ScheduleRun{status: "failed", error: error}} =
               Worker.perform(claimed_run(schedule_fixture()).id)

      assert error =~ "no service account"
      refute_received {:before_query, _}
    end

    test "run telemetry brackets a run" do
      scheduler([])
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :schedule, :run, :start], [:lotus, :schedule, :run, :stop]],
        fn event, measurements, metadata, _ -> send(pid, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      assert {:ok, _} = Worker.perform(claimed_run(schedule_fixture()).id)
      assert_received {[:lotus, :schedule, :run, :start], _, %{run: %{status: "running"}}}

      assert_received {[:lotus, :schedule, :run, :stop], %{row_count: 2},
                       %{run: %{status: "succeeded"}, schedule: %Schedule{name: "Nightly"}}}
    end
  end

  test "the scheduler process ticks on its interval" do
    :persistent_term.put({PidExecutor, :pid}, self())
    on_exit(fn -> :persistent_term.erase({PidExecutor, :pid}) end)
    scheduler(executor: PidExecutor)
    due!(schedule_fixture(), DateTime.add(DateTime.utc_now(), -60))

    pid = start_supervised!({Scheduler, interval: 200, name: :lotus_test_scheduler})
    Mimic.allow(Config, self(), pid)
    assert_receive {:execute, _run_id}, 2_000
  end

  test "the inline executor performs the run in a task" do
    scheduler([])
    schedule = due!(schedule_fixture(), ~U[2026-10-24 03:00:00.000000Z])
    stub(Config, :scheduler, fn -> [executor: Lotus.Scheduler.Executors.Inline] end)

    assert [run_id] = Scheduler.tick(now: ~U[2026-10-24 12:00:00.000000Z])

    run =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(20)
        run = Repo.get!(ScheduleRun, run_id)
        if run.status == "succeeded", do: run
      end)

    assert %ScheduleRun{row_count: 2} = run
    assert schedule.id == run.schedule_id
  end
end
