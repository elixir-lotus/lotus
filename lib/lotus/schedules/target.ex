defmodule Lotus.Schedules.Target do
  @moduledoc """
  A kind of thing a schedule runs besides a saved query and a dashboard,
  which an extension registers by name, such as Lotus Pro's workflows:

      config :lotus,
        scheduler: [targets: %{"workflow" => Lotus.Pro.Workflows.ScheduleTarget}]

  A schedule names one by `target_type` (the name) and `target_id` (the
  thing, as text). The scheduler runs it with `c:run/2`, and its results
  go to the schedule's deliveries, or are read by its alert rule (the
  first result), as a query's are.
  """

  @typedoc "One thing a schedule may run, as a picker shows it."
  @type entry :: %{id: String.t(), name: String.t(), description: String.t() | nil}

  @doc "What one is called, for people: `\"Workflow\"`."
  @callback label() :: String.t()

  @doc """
  The things of this kind the caller may schedule, for a picker. `opts`
  has the caller's `:context` and `:scope`.
  """
  @callback list(opts :: keyword()) :: [entry()]

  @doc "One of them by id, for whoever `opts` names, or `nil`."
  @callback get(id :: String.t(), opts :: keyword()) :: entry() | nil

  @doc """
  Runs the schedule's target for one run: its results, titled, as a
  delivery sends them. `opts` has the run's `:context` and `:scope` (the
  scheduler's `:actor`), which the target may use or replace with its own.
  """
  @callback run(schedule :: Lotus.Storage.Schedule.t(), opts :: keyword()) ::
              {:ok, [%{title: String.t(), result: Lotus.Result.t()}]} | {:error, term()}
end
