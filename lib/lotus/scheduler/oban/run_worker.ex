# Needs Oban, an optional dependency.
if Code.ensure_loaded?(Oban) do
  defmodule Lotus.Scheduler.Oban.RunWorker do
    @moduledoc """
    Performs one claimed run with `Lotus.Scheduler.Worker.perform/2`, as an Oban
    job. A failed run returns an error so Oban retries it; each attempt takes
    the run again, and the run records the last. See `Lotus.Scheduler.Oban`.
    """

    use Oban.Worker, unique: [period: :infinity, keys: [:run_id]]

    alias Lotus.Scheduler.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"run_id" => run_id}, attempt: attempt}) do
      case Worker.perform(run_id, retry: attempt > 1) do
        {:ok, %{status: "succeeded"}} -> :ok
        {:ok, %{error: error}} -> {:error, error}
        {:error, :not_pending} -> :ok
        {:error, :not_found} -> {:cancel, :not_found}
      end
    end
  end
end
