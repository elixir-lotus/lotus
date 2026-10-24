# Needs Oban, an optional dependency.
if Code.ensure_loaded?(Oban) do
  defmodule Lotus.Scheduler.Oban.TickWorker do
    @moduledoc """
    Calls `Lotus.Scheduler.tick/1`: what Oban's cron plugin runs every minute
    to find the schedules that are due. See `Lotus.Scheduler.Oban`.
    """

    use Oban.Worker, max_attempts: 1, unique: [period: 50]

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      Lotus.Scheduler.tick()
      :ok
    end
  end
end
