defmodule Lotus.Scheduler.Worker do
  @moduledoc """
  Performs one claimed run of a schedule: what an executor calls.

  The run moves from `"pending"` to `"running"` in one conditional update, so
  an executor that hands the same run over twice (a job runner retrying it)
  performs it once. It then runs the schedule's query with `Lotus.run_query/2`
  (its `params` as `:vars`) or its dashboard with `Lotus.run_dashboard/2`
  (its `params` as `:filter_values`), with `cache: :refresh` when a cache is
  configured, and records the outcome: `"succeeded"` with the rows returned,
  or `"failed"` with the error. A dashboard run fails when any of its query
  cards fails; `details` names each failed card.

  A schedule with a `rule` is an alert: the run checks the rule against the
  query's result, records the change in the schedule's `state`, and sends
  the deliveries only when the status changes. See `Lotus.Schedules.Alert`.

  ## The actor

  A run has no `:context` or `:scope` by default: it runs as the app, and
  middleware and visibility see it that way. The `:actor` option of the
  scheduler config gives it one:

      config :lotus, scheduler: [enabled: true, actor: {MyApp.Lotus, :schedule_actor, []}]

      def schedule_actor(%Lotus.Storage.Schedule{} = schedule) do
        {:ok, context: %{system: :scheduler}, scope: %{tenant_id: schedule.tenant_id}}
      end

  It is called with the schedule first, then the configured arguments, and
  returns `{:ok, keyword}` with `:context` and `:scope`, or `{:error, reason}`
  to fail the run without running anything.

  `[:lotus, :schedule, :run, :start | :stop | :exception]` telemetry brackets
  each run; see `Lotus.Telemetry`.
  """

  import Ecto.Query

  alias Lotus.{Config, Dashboards, Delivery, Result, Telemetry}
  alias Lotus.Delivery.Content
  alias Lotus.Schedules.Alert
  alias Lotus.Storage.{Query, Schedule, ScheduleRun}

  @doc """
  Performs the run `run_id`. Returns `{:ok, run}` with the run as recorded,
  `{:error, :not_found}`, or `{:error, :not_pending}` for a run that was
  already taken.

  With `retry: true` a `"failed"` run is taken again too, and a `"running"`
  one left by an attempt that died: a job runner that retries a run, and
  runs one attempt at a time, passes it. The run records its last attempt.
  """
  @spec perform(term(), keyword()) ::
          {:ok, ScheduleRun.t()} | {:error, :not_found | :not_pending}
  def perform(run_id, opts \\ []) do
    repo = Lotus.repo()
    started_at = now()

    takeable =
      if Keyword.get(opts, :retry, false),
        do: ["pending", "running", "failed"],
        else: ["pending"]

    {taken, _} =
      repo.update_all(
        from(r in ScheduleRun, where: r.id == ^run_id and r.status in ^takeable),
        set: [status: "running", started_at: started_at, error: nil, updated_at: started_at]
      )

    case {taken, repo.get(ScheduleRun, run_id)} do
      {_taken, nil} -> {:error, :not_found}
      {0, _run} -> {:error, :not_pending}
      {1, run} -> run |> repo.preload(schedule: [:query]) |> perform_run()
    end
  end

  defp perform_run(%ScheduleRun{schedule: schedule} = run) do
    metadata = %{schedule: schedule, run: run}
    start_time = Telemetry.schedule_run_start(metadata)

    outcome =
      try do
        execute(schedule)
      rescue
        e -> {:error, Exception.message(e)}
      end

    finished_at = now()

    {attrs, state} =
      case outcome do
        {:ok, row_count, details, results} ->
          succeeded(run, schedule, row_count, details, results)

        {:error, reason, details} ->
          {%{status: "failed", error: describe(reason), details: details},
           errored(schedule, reason)}

        {:error, reason} ->
          {%{status: "failed", error: describe(reason)}, errored(schedule, reason)}
      end

    {:ok, run} =
      run
      |> ScheduleRun.update_changeset(Map.put(attrs, :finished_at, finished_at))
      |> Lotus.repo().update()

    Lotus.repo().update_all(
      from(s in Schedule, where: s.id == ^schedule.id),
      set: [last_run_at: run.scheduled_for] ++ if(state, do: [state: state], else: [])
    )

    if run.status == "succeeded",
      do: Telemetry.schedule_run_stop(start_time, %{metadata | run: run}),
      else: Telemetry.schedule_run_exception(start_time, %{metadata | run: run})

    {:ok, run}
  end

  defp execute(%Schedule{} = schedule) do
    with {:ok, actor} <- actor(schedule) do
      opts = actor ++ cache_opts()
      execute(schedule, opts)
    end
  end

  defp execute(%Schedule{query: %Query{} = query, params: params}, opts) do
    # A schedule only reads, whatever the source allows.
    case Lotus.run_query(query, [vars: params || %{}, read_only: true] ++ opts) do
      {:ok, %Result{num_rows: rows} = result} ->
        {:ok, rows || 0, %{}, [%{title: query.name, result: result}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(%Schedule{dashboard_id: id, params: params}, opts) when not is_nil(id) do
    results =
      Dashboards.run_dashboard(id, [filter_values: params || %{}, parallel: false] ++ opts)

    failed =
      for {card_id, {:error, reason}} <- results,
          into: %{},
          do: {to_string(card_id), describe(reason)}

    rows =
      for {_card_id, {:ok, %Result{num_rows: n}}} <- results,
          reduce: 0,
          do: (acc -> acc + (n || 0))

    if failed == %{},
      do: {:ok, rows, %{"cards" => map_size(results)}, card_results(id, results)},
      else:
        {:error, "#{map_size(failed)} of #{map_size(results)} cards failed",
         %{"failed_cards" => failed}}
  end

  defp execute(%Schedule{}, _opts),
    do: {:error, "the schedule's query or dashboard no longer exists"}

  # The results of the query cards, in the dashboard's order, titled by the
  # card or else its query.
  defp card_results(dashboard_id, results) do
    for card <- Dashboards.list_dashboard_cards(dashboard_id, preload: [:query]),
        {:ok, %Result{} = result} <- [Map.get(results, card.id)] do
      %{title: card.title || (card.query && card.query.name) || "Card #{card.id}", result: result}
    end
  end

  # The run's attributes and, for an alert, the schedule's new state. An
  # alert's state is kept only when its run succeeds, so a change whose
  # deliveries failed is sent again.
  defp succeeded(run, %Schedule{rule: nil} = schedule, row_count, details, results),
    do: {deliver(run, schedule, row_count, details, results, nil), nil}

  defp succeeded(_run, schedule, row_count, details, []) do
    message = "the alert has no result to read"

    {%{status: "failed", row_count: row_count, error: message, details: details},
     Alert.errored(schedule.state, message, now())}
  end

  defp succeeded(run, schedule, row_count, details, [%{result: result} | _] = results) do
    %Schedule{rule: rule, state: state} = schedule

    case Alert.evaluate(rule, result, state) do
      {:ok, holds?, value} ->
        {next, change} = Alert.transition(state, rule, holds?, value, now())

        details =
          Map.put(details, "alert", %{
            "status" => next["status"],
            "value" => value,
            "change" => change
          })

        if change do
          alert = %{status: change, value: value, message: Alert.describe(rule, change, value)}
          attrs = deliver(run, schedule, row_count, details, results, alert)
          {attrs, if(attrs.status == "succeeded", do: next)}
        else
          {%{status: "succeeded", row_count: row_count, details: details}, next}
        end

      {:error, message} ->
        {%{status: "failed", row_count: row_count, error: message, details: details},
         Alert.errored(state, message, now())}
    end
  end

  defp errored(%Schedule{rule: nil}, _reason), do: nil
  defp errored(%Schedule{state: state}, reason), do: Alert.errored(state, describe(reason), now())

  # After a run succeeds: each delivery that has not succeeded on an earlier
  # attempt of this run is sent, and its outcome recorded. A failed delivery
  # fails the run, so a job runner retries it.
  defp deliver(_run, %Schedule{deliveries: []}, row_count, details, _results, _alert),
    do: %{status: "succeeded", row_count: row_count, details: details}

  defp deliver(run, schedule, row_count, details, results, alert) do
    content = %Content{
      title: schedule.name,
      results: results,
      schedule: schedule,
      run: run,
      alert: alert
    }

    previous = get_in(run.details || %{}, ["deliveries"]) || %{}
    outcomes = Delivery.deliver_all(content, schedule.deliveries, previous)
    details = Map.put(details, "deliveries", outcomes)
    failed = Enum.count(outcomes, fn {_id, outcome} -> outcome["status"] == "failed" end)

    if failed == 0,
      do: %{status: "succeeded", row_count: row_count, details: details},
      else: %{
        status: "failed",
        row_count: row_count,
        details: details,
        error: "#{failed} of #{map_size(outcomes)} deliveries failed"
      }
  end

  defp actor(schedule) do
    case Keyword.get(Config.scheduler(), :actor) do
      nil ->
        {:ok, []}

      {module, function, args} ->
        case apply(module, function, [schedule | args]) do
          {:ok, actor} when is_list(actor) -> {:ok, Keyword.take(actor, [:context, :scope])}
          {:error, reason} -> {:error, {:actor, reason}}
        end
    end
  end

  defp cache_opts do
    case Config.cache_adapter() do
      {:ok, _adapter} -> [cache: :refresh]
      :error -> []
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe({:actor, reason}), do: "the actor callback refused the run: #{describe(reason)}"
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now()
end
