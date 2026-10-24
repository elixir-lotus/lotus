defmodule Lotus.Scheduler do
  @moduledoc """
  Finds the schedules that are due and claims each run once per cluster.

  Started by `Lotus.Supervisor` only with `config :lotus, scheduler: [enabled: true]`.
  Every `:interval` milliseconds (30 seconds by default) it calls `tick/1`.
  Every node with the scheduler enabled ticks; the claim makes each run
  happen once:

    1. A schedule is due when it is enabled and its `next_run_at` has passed.
    2. The node inserts a run for the schedule and that slot into
       `lotus_schedule_runs`. The row is unique per schedule and slot, so one
       node's insert succeeds and the others' fail.
    3. Every node that saw the slot moves `next_run_at` to the schedule's next
       run after now, in one conditional update; the moves agree, so it does
       not matter which lands. Slots missed while no node ran are skipped:
       the schedule runs once for the latest and goes on from the next.
    4. The node that claimed the run hands it to the `:executor`
       (`Lotus.Scheduler.Executor`).

  It needs no coordination between nodes beyond the storage database, and
  works the same on PostgreSQL, MySQL and SQLite.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Lotus.{Config, Schedules}
  alias Lotus.Storage.{Schedule, ScheduleRun}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, Keyword.get(Config.scheduler(), :interval, 30_000)),
      task_supervisor: Keyword.get(opts, :task_supervisor)
    }

    schedule_tick(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    tick(executor_opts: [task_supervisor: state.task_supervisor])
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)

  @doc """
  Claims and hands over every run due at `:now` (default the current time).
  Returns the ids of the runs this call claimed.

  `Lotus.Scheduler` calls it on its interval; a test or a host that drives
  scheduling itself can call it directly.
  """
  @spec tick(keyword()) :: [term()]
  def tick(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    executor = Keyword.get(Config.scheduler(), :executor, Lotus.Scheduler.Executors.Inline)
    executor_opts = Keyword.get(opts, :executor_opts, []) |> drop_nil_values()

    now
    |> due()
    |> Enum.flat_map(fn schedule ->
      claimed = claim(schedule)
      advance(schedule, now)

      case claimed do
        {:ok, run} ->
          hand_over(executor, run, executor_opts)
          [run.id]

        :taken ->
          []
      end
    end)
  rescue
    e ->
      Logger.error("Lotus.Scheduler tick failed: " <> Exception.format(:error, e, __STACKTRACE__))
      []
  end

  defp due(now) do
    from(s in Schedule,
      where: s.enabled == true and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
      order_by: [asc: s.next_run_at]
    )
    |> Lotus.repo().all()
  end

  defp claim(%Schedule{id: id, next_run_at: slot}) do
    case id |> ScheduleRun.claim_changeset(slot) |> Lotus.repo().insert() do
      {:ok, run} -> {:ok, run}
      {:error, _changeset} -> :taken
    end
  end

  # Conditional on the slot, so a node with a stale view of the schedule (it
  # was edited meanwhile) leaves the new next run alone.
  defp advance(%Schedule{id: id, next_run_at: slot} = schedule, now) do
    Lotus.repo().update_all(
      from(s in Schedule, where: s.id == ^id and s.next_run_at == ^slot),
      set: [next_run_at: Schedules.next_run(schedule, now)]
    )
  end

  defp hand_over(executor, run, opts) do
    case executor.execute(run.id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Lotus.Scheduler could not hand run #{run.id} over: #{inspect(reason)}")
    end
  end

  defp drop_nil_values(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
