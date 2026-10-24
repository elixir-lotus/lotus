defmodule Lotus.Scheduler.Executors.Inline do
  @moduledoc """
  The default `Lotus.Scheduler.Executor`: performs a run in a task of Lotus's
  task supervisor, on the node that claimed it.

  A run that fails is recorded as failed and is not retried; the schedule
  goes on at its next slot. A node that stops while a run is in progress
  leaves the run `"running"`.
  """

  @behaviour Lotus.Scheduler.Executor

  alias Lotus.Scheduler.Worker

  @impl true
  def execute(run_id, opts) do
    task_supervisor =
      Keyword.get(opts, :task_supervisor, Lotus.Supervisor.task_supervisor_name(Lotus))

    case Task.Supervisor.start_child(task_supervisor, fn -> Worker.perform(run_id) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
