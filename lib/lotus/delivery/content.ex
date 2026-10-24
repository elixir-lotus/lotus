defmodule Lotus.Delivery.Content do
  @moduledoc """
  What a delivery sends: the results of one run of a schedule.

    * `:title` - The schedule's name
    * `:results` - One `%{title: String.t(), result: Lotus.Result.t()}` per
      result: the query's, or each query card's of a dashboard, in the
      dashboard's order
    * `:schedule` - The `Lotus.Storage.Schedule`
    * `:run` - The `Lotus.Storage.ScheduleRun`
    * `:alert` - For an alert, the change it sends (`Lotus.Schedules.Alert`):
      `:status` (`"firing"`, or `"ok"` when it recovered), the `:value` read
      and a `:message` saying what happened. `nil` for other schedules
  """

  @enforce_keys [:title, :results, :schedule, :run]
  defstruct [:title, :results, :schedule, :run, :alert]

  @type result :: %{title: String.t(), result: Lotus.Result.t()}

  @type alert :: %{status: String.t(), value: term(), message: String.t()}

  @type t :: %__MODULE__{
          title: String.t(),
          results: [result()],
          schedule: Lotus.Storage.Schedule.t(),
          run: Lotus.Storage.ScheduleRun.t(),
          alert: alert() | nil
        }
end
