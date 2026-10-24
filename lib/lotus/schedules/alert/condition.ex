defmodule Lotus.Schedules.Alert.Condition do
  @moduledoc """
  A condition of alert rules, next to the built-in ones (`"above"`,
  `"below"`, `"equals"`, `"any_rows"`, `"no_rows"`). Lotus Pro or your app
  registers it by name:

      config :lotus, alerts: [conditions: %{"change" => MyApp.Alerts.Change}]

  A rule names it as its `condition`, and keeps its settings in `options`:

      rule: %{condition: "change", column: "revenue", options: %{"percent" => 20}}

  A condition reads the run's result, and the schedule's `state` with what
  earlier runs recorded (the last `"value"`, among others), so it can compare
  a value with the last one. Lotus keeps the status and sends the deliveries
  on a change, as for a built-in condition (`Lotus.Schedules.Alert`).

  A name here wins over a built-in one.
  """

  alias Lotus.Result
  alias Lotus.Storage.ScheduleRule

  @doc """
  Checks the rule's settings when the schedule is saved: its `options`, and
  its `column` and `threshold` if it reads them. `{:error, message}` refuses
  the rule.
  """
  @callback validate(ScheduleRule.t()) :: :ok | {:error, String.t()}

  @doc """
  Checks the condition on a run's result, given the schedule's `state`.
  Returns `{:ok, holds?, value}`, the value as JSON has it (it becomes the
  state's `"value"`), or `{:error, message}` for a run that could not read
  it.
  """
  @callback evaluate(ScheduleRule.t(), Result.t(), state :: map()) ::
              {:ok, boolean(), term()} | {:error, String.t()}

  @doc """
  A sentence for a change of status to `status` (`"firing"` or `"ok"`) with
  `value`, sent with the deliveries.
  """
  @callback describe(ScheduleRule.t(), status :: String.t(), value :: term()) :: String.t()
end
