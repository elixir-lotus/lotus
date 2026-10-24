# Needs Oban, an optional dependency.
if Code.ensure_loaded?(Oban) do
  defmodule Lotus.Scheduler.Oban do
    @moduledoc """
    Runs schedules through the host's Oban: Oban finds what is due and performs
    each run, with its retries, its queues and its dashboard. Lotus starts no
    process.

        # config/config.exs
        config :my_app, Oban,
          repo: MyApp.Repo,
          queues: [default: 10, lotus: 5],
          plugins: [
            {Oban.Plugins.Cron, crontab: [{"* * * * *", Lotus.Scheduler.Oban.TickWorker}]}
          ]

        config :lotus,
          scheduler: [executor: Lotus.Scheduler.Oban, oban: [queue: :lotus]]

    Leave `scheduler: [enabled: ...]` off: Oban's cron plugin runs
    `Lotus.Scheduler.Oban.TickWorker` every minute on one node (its leader),
    which calls `Lotus.Scheduler.tick/1`. Every run that tick claims becomes a
    `Lotus.Scheduler.Oban.RunWorker` job, unique per run, retried up to
    `:max_attempts` times when it fails. Schedules are rows people create, so
    a static crontab entry that checks them every minute is all Oban needs:
    no dynamic cron.

    ## Options

    `config :lotus, scheduler: [oban: [...]]`:

      * `:name` - The Oban instance (default `Oban`)
      * `:queue` - The queue of run jobs (default `:default`)
      * `:max_attempts` - Attempts per run (default 3)
    """

    @behaviour Lotus.Scheduler.Executor

    alias Lotus.Scheduler.Oban.RunWorker

    @impl true
    def execute(run_id, _opts) do
      options = Keyword.get(Lotus.Config.scheduler(), :oban, [])
      name = Keyword.get(options, :name, Oban)

      job =
        RunWorker.new(%{"run_id" => run_id},
          queue: Keyword.get(options, :queue, :default),
          max_attempts: Keyword.get(options, :max_attempts, 3)
        )

      case Oban.insert(name, job) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
