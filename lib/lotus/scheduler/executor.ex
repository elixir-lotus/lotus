defmodule Lotus.Scheduler.Executor do
  @moduledoc """
  Performs the runs `Lotus.Scheduler` claims.

  The scheduler decides which run is due and claims it once per cluster; an
  executor decides where and how it is performed. `Lotus.Scheduler.Executors.Inline`,
  the default, performs it in a task on the node that claimed it. An executor
  for a job runner enqueues it instead, for retries and a job dashboard.
  Either way the work is `Lotus.Scheduler.Worker.perform/1`.

      config :lotus, scheduler: [enabled: true, executor: MyApp.LotusExecutor]
  """

  @doc """
  Performs, or arranges to perform, the claimed run `run_id` by calling
  `Lotus.Scheduler.Worker.perform/1` with it. Returns once the run is handed
  over, not when it ends.
  """
  @callback execute(run_id :: term(), opts :: keyword()) :: :ok | {:error, term()}
end
