defmodule Lotus.Schedules.Alert do
  @moduledoc """
  Alerts: a query schedule with a `rule` (`Lotus.Storage.ScheduleRule`).

      {:ok, schedule} =
        Lotus.Schedules.create_schedule(%{
          name: "Open tickets",
          query_id: query.id,
          cron: "*/15 * * * *",
          rule: %{condition: "above", column: "open", threshold: 500},
          deliveries: [%{channel: "webhook", format: "json", config: %{"url" => "https://..."}}]
        })

  Each run reads one value from the result, the `column` of the first row
  or else the number of rows, and checks the condition. The schedule's
  `state` keeps the outcome:

    * `"status"` - `"ok"` or `"firing"`
    * `"value"` - The value the last run read
    * `"checked_at"` - When it was read
    * `"fired_at"`, `"recovered_at"` - When the status last went to
      `"firing"` and back to `"ok"`
    * `"error"`, `"errored_at"` - Why the last run could not read the value,
      until a run can again

  The deliveries are sent when the status changes: when the condition starts
  holding, and when it stops if `notify_recovery` (the default). A run that
  finds the status unchanged sends nothing, so an alert that stays firing
  is sent once. A new schedule, or one whose rule is changed, starts from
  `"ok"`, so a condition that already holds is sent on the first run.

  A run that fails (the query errors, or the value is missing or not a
  number) leaves the status as it was and records the error: it sends
  nothing, and the run is `"failed"` as any other, for whatever watches
  runs. A run whose deliveries fail leaves the state as it was too, so the
  retry, or the next run, sends the change again.

  The content of the deliveries has `alert` (`Lotus.Delivery.Content`): the
  status, the value and a sentence saying what happened.

  ## More conditions

  Lotus Pro or your app adds conditions by name, such as one that fires when
  a value changes by more than a share since the last run; see
  `Lotus.Schedules.Alert.Condition`. A rule names it as its `condition` and
  keeps its settings in `options`. It reads the schedule's `state` too, with
  the last run's `"value"`. The status, the deliveries and the errors work
  as for the built-in conditions.
  """

  alias Lotus.Result
  alias Lotus.Storage.ScheduleRule

  @type status :: String.t()

  @builtin ~w(above below equals any_rows no_rows)

  @doc """
  The names a rule's `condition` may take: the built-in ones and those
  registered under `config :lotus, alerts: [conditions: %{...}]`
  (`Lotus.Schedules.Alert.Condition`).
  """
  @spec conditions() :: [String.t()]
  def conditions, do: Enum.uniq(@builtin ++ Map.keys(configured()))

  @doc false
  # The module of a registered condition, or nil for a built-in one.
  @spec registered(String.t() | nil) :: module() | nil
  def registered(condition), do: Map.get(configured(), condition)

  defp configured, do: Keyword.get(Lotus.Config.alerts(), :conditions) || %{}

  @doc """
  Reads the rule's value from `result` and checks the condition. Returns
  `{:ok, holds?, value}`, the value as JSON has it, or `{:error, message}`.
  `subject` is what returned the result, in the messages: `"the query"`,
  or for a schedule target, such as `"the workflow"`.
  """
  @spec evaluate(ScheduleRule.t(), Result.t(), map(), String.t()) ::
          {:ok, boolean(), term()} | {:error, String.t()}
  def evaluate(rule, result, state \\ %{}, subject \\ "the query")

  def evaluate(%ScheduleRule{condition: condition} = rule, result, state, subject) do
    case registered(condition) do
      nil when condition in @builtin -> evaluate_builtin(rule, result, subject)
      nil -> {:error, "the condition #{inspect(condition)} is not registered"}
      module -> module.evaluate(rule, result, state || %{})
    end
  end

  defp evaluate_builtin(%ScheduleRule{condition: "any_rows"}, result, _subject) do
    count = row_count(result)
    {:ok, count > 0, count}
  end

  defp evaluate_builtin(%ScheduleRule{condition: "no_rows"}, result, _subject) do
    count = row_count(result)
    {:ok, count == 0, count}
  end

  defp evaluate_builtin(
         %ScheduleRule{condition: condition, threshold: threshold} = rule,
         result,
         subject
       ) do
    with {:ok, value} <- value(rule, result, subject),
         {:ok, number} <- to_decimal(value, rule) do
      {:ok, compare(condition, number, threshold), Lotus.Value.for_json(value)}
    end
  end

  defp value(%ScheduleRule{column: nil}, result, _subject), do: {:ok, row_count(result)}

  defp value(%ScheduleRule{column: column}, %Result{columns: columns, rows: rows}, subject) do
    case {Enum.find_index(columns, &(&1 == column)), rows} do
      {nil, _rows} -> {:error, "the result has no column #{inspect(column)}"}
      {_index, []} -> {:error, "#{subject} returned no rows to read #{inspect(column)} from"}
      {index, [row | _]} -> {:ok, Enum.at(row, index)}
    end
  end

  defp to_decimal(value, _rule) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp to_decimal(value, _rule) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp to_decimal(%Decimal{} = value, _rule), do: {:ok, value}

  defp to_decimal(value, rule) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> {:ok, decimal}
      _ -> not_a_number(value, rule)
    end
  end

  defp to_decimal(value, rule), do: not_a_number(value, rule)

  defp not_a_number(nil, rule), do: {:error, "#{label(rule)} is empty"}

  defp not_a_number(value, rule),
    do: {:error, "#{label(rule)} is not a number: #{inspect(Lotus.Value.for_json(value))}"}

  defp compare("above", number, threshold), do: Decimal.compare(number, threshold) == :gt
  defp compare("below", number, threshold), do: Decimal.compare(number, threshold) == :lt
  defp compare("equals", number, threshold), do: Decimal.compare(number, threshold) == :eq

  defp row_count(%Result{num_rows: nil, rows: rows}), do: length(rows)
  defp row_count(%Result{num_rows: count}), do: count

  @doc """
  The state after a run that read `value`, and the status to send, or `nil`
  when the deliveries have nothing to send.
  """
  @spec transition(map(), ScheduleRule.t(), boolean(), term(), DateTime.t()) ::
          {map(), status() | nil}
  def transition(state, %ScheduleRule{} = rule, holds?, value, %DateTime{} = now) do
    status = if holds?, do: "firing", else: "ok"
    at = DateTime.to_iso8601(now)

    next =
      (state || %{})
      |> Map.drop(["error", "errored_at"])
      |> Map.merge(%{"status" => status, "value" => value, "checked_at" => at})

    case {Map.get(state || %{}, "status", "ok"), status} do
      {"ok", "firing"} -> {Map.put(next, "fired_at", at), "firing"}
      {"firing", "ok"} -> {Map.put(next, "recovered_at", at), if(rule.notify_recovery, do: "ok")}
      _unchanged -> {next, nil}
    end
  end

  @doc "The state after a run that could not read the value."
  @spec errored(map(), String.t(), DateTime.t()) :: map()
  def errored(state, message, %DateTime{} = now) do
    Map.merge(state || %{}, %{"error" => message, "errored_at" => DateTime.to_iso8601(now)})
  end

  @doc """
  A sentence for a change to `status`: `"open is 512, above 500"`, `"open
  is 480, no longer above 500"`, `"the query returned 3 rows"`; with
  `subject`, as `evaluate/4` takes it, `"the workflow returned 3 rows"`.
  """
  @spec describe(ScheduleRule.t(), status(), term(), String.t()) :: String.t()
  def describe(%ScheduleRule{condition: condition} = rule, status, value, subject \\ "the query") do
    case registered(condition) do
      nil -> describe_builtin(rule, status, value, subject)
      module -> module.describe(rule, status, value)
    end
  end

  defp describe_builtin(%ScheduleRule{condition: condition}, _status, count, subject)
       when condition in ["any_rows", "no_rows"] do
    case count do
      0 -> "#{subject} returned no rows"
      1 -> "#{subject} returned 1 row"
      n -> "#{subject} returned #{n} rows"
    end
  end

  defp describe_builtin(
         %ScheduleRule{condition: condition, threshold: threshold} = rule,
         status,
         value,
         _subject
       ) do
    still = if status == "firing", do: "", else: "no longer "

    "#{label(rule)} is #{Lotus.Value.to_display_string(value)}, #{still}#{condition} " <>
      Decimal.to_string(threshold, :normal)
  end

  defp label(%ScheduleRule{column: nil}), do: "the row count"
  defp label(%ScheduleRule{column: column}), do: column
end
