defmodule Lotus.Delivery.Content do
  @moduledoc """
  What a delivery sends: the results of one run of a schedule.

    * `:title` - The schedule's name
    * `:results` - One `%{title: String.t(), result: Lotus.Result.t()}` per
      result: the query's, or each query card's of a dashboard, in the
      dashboard's order
    * `:schedule` - The `Lotus.Storage.Schedule`
    * `:run` - The `Lotus.Storage.ScheduleRun`
  """

  @enforce_keys [:title, :results, :schedule, :run]
  defstruct [:title, :results, :schedule, :run]

  @type result :: %{title: String.t(), result: Lotus.Result.t()}

  @type t :: %__MODULE__{
          title: String.t(),
          results: [result()],
          schedule: Lotus.Storage.Schedule.t(),
          run: Lotus.Storage.ScheduleRun.t()
        }
end
