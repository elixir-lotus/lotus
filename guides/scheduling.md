# Scheduling

A schedule runs a saved query or a dashboard on a cron expression, in a time
zone, once per cluster. Every run is recorded. A run reads fresh data and,
when a cache is configured, leaves the cache warm, so a heavy dashboard
scheduled at 07:30 opens instantly at 08:00.

A schedule can also deliver its results: as CSV, JSON or an HTML table, to a
webhook or to a channel your app adds, such as email (see
[Delivering results](#delivering-results)).

## Schedules

```elixir
{:ok, schedule} =
  Lotus.Schedules.create_schedule(%{
    name: "Weekly revenue",
    dashboard_id: dashboard.id,
    cron: "0 8 * * MON",
    time_zone: "Europe/Lisbon",
    params: %{"region" => "north"}
  })
```

- `query_id` or `dashboard_id`: what the schedule runs, one of the two.
- `cron`: the five standard fields, `minute hour day month weekday`.
- `time_zone`: an IANA zone, `"Etc/UTC"` by default.
- `params`: the variables of a query, or the filter values of a dashboard.
- `enabled`: a disabled schedule keeps its settings and never runs.

`Lotus.Schedules` lists, updates and deletes them, and `list_runs/2` lists a
schedule's runs, the latest first, with their status, row count and error.
Creating, updating and deleting a schedule fire the content change middleware
with resource `:schedule`, as queries and dashboards do.

### Time zones

The cron fields are the wall clock of the schedule's time zone. `"0 8 * * MON"`
in `"Europe/Lisbon"` runs at 08:00 in Lisbon all year: 07:00 UTC in summer and
08:00 UTC in winter. Lotus computes each next run with that day's offset.

On the two days a year the clock changes, a time the clock skips (01:30 when it
jumps from 01:00 to 02:00) runs at the first moment after the gap, and a time
the clock repeats runs once, at its first occurrence.

The time zone rules come from the time zone database your application
configures (`config :elixir, :time_zone_database, ...`). With none, Lotus uses
its own [`tz`](https://hex.pm/packages/tz), passed to each calculation: it never
sets the global one. `config :lotus, scheduler: [time_zone_database: ...]`
picks one for Lotus alone.

## Running schedules

Nothing runs until you choose how. There are two ways.

### With Oban

If your app runs [Oban](https://hex.pm/packages/oban), let it do the work:
Oban's cron plugin checks for due schedules every minute on one node, and each
run is an Oban job with Oban's retries, queues and dashboard. Lotus starts no
process.

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, lotus: 5],
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Lotus.Scheduler.Oban.TickWorker}]}
  ]

config :lotus,
  scheduler: [executor: Lotus.Scheduler.Oban, oban: [queue: :lotus, max_attempts: 3]]
```

A run that fails is retried up to `:max_attempts` times; its row records the
last attempt. `oban: [name: ...]` names the Oban instance when it is not `Oban`.

Schedules are rows people create, so the one static crontab entry above is all
Oban needs: no dynamic cron.

### Without Oban

```elixir
config :lotus, scheduler: [enabled: true]
```

`Lotus.Scheduler` starts on the node and looks for due schedules every 30
seconds (`interval: 30_000`). Each run is performed in a task on the node that
claimed it. A run that fails is recorded and not retried; the schedule goes on
at its next slot.

### Once per cluster

Every node that checks for due schedules (every node with `enabled: true`, or
Oban's leader) claims a run by inserting it into `lotus_schedule_runs`, which is
unique per schedule and slot. One insert succeeds, so each slot runs once, with
no coordination between nodes beyond the storage database. It works the same on
PostgreSQL, MySQL and SQLite.

Slots missed while nothing ran (a deploy, an outage) run once, for the latest
of them, then the schedule goes on from its next slot.

### Your own job runner

`executor:` takes any module implementing `Lotus.Scheduler.Executor`. It is
handed each claimed run and calls `Lotus.Scheduler.Worker.perform/2` with it,
wherever it likes. A runner that ticks by itself calls `Lotus.Scheduler.tick/1`.

## Who a run runs as

A run goes through `Lotus.run_query/2` or `Lotus.run_dashboard/2` like any
other: visibility rules, middleware and session settings apply. By default it
has no `:context` or `:scope`: it runs as your app. To run it as someone,
for example a service account your access rules know, give the scheduler an
actor callback:

```elixir
config :lotus, scheduler: [enabled: true, actor: {MyApp.Lotus, :schedule_actor, []}]
```

```elixir
def schedule_actor(%Lotus.Storage.Schedule{}) do
  {:ok, context: %{role: :scheduler}, scope: nil}
end
```

It receives the schedule, then the arguments you configured, and returns the
`:context` and `:scope`, or `{:error, reason}` to fail the run without running
anything.

## Delivering results

A schedule's `deliveries` send each successful run somewhere. Each names a
channel, a format and the channel's settings:

```elixir
Lotus.Schedules.create_schedule(%{
  name: "Weekly revenue",
  dashboard_id: dashboard.id,
  cron: "0 8 * * MON",
  time_zone: "Europe/Lisbon",
  deliveries: [
    %{channel: "webhook", format: "csv", config: %{"url" => "https://hooks.example.com/lotus"}},
    %{channel: "email", format: "html", config: %{"to" => "founders@example.com"}}
  ]
})
```

### Formats

- `"csv"`: a CSV file per result. A dashboard gives one per query card.
- `"json"`: one file with the title and every result's columns and rows.
- `"html"`: one document with a table per result, every value escaped. Fits an
  email body.

### The webhook channel

`"webhook"` POSTs the attachments as JSON to `config["url"]`, with any
`config["headers"]`. The URL must be `https`;
`config :lotus, delivery: [webhook: [allow_http: true]]` allows `http` for a
receiver on a private network. A 2xx response is a delivery.

It sends with [Req](https://hex.pm/packages/req), an optional dependency: add
`{:req, "~> 0.5"}` to your deps. An app with the AI features has it already.
Without it a webhook delivery is refused when the schedule is saved.

### Your own channels and formats

A channel implements `Lotus.Delivery.Channel` (`formats/0`, `validate_config/1`,
`deliver/3`), a format `Lotus.Delivery.Format` (`render/1`). Register them by
name:

```elixir
config :lotus,
  delivery: [
    channels: %{"email" => MyApp.Lotus.EmailChannel},
    formats: %{"xlsx" => MyApp.Lotus.XlsxFormat}
  ]
```

A delivery stores the names, never a module: its settings are data people
enter, so a channel validates them and takes nothing else from them.

### Outcomes and retries

Each delivery's outcome is recorded on the run, in `details["deliveries"]` by
delivery id. A failed delivery fails the run. With Oban the run is retried, and
the retry sends only the deliveries that failed, so nobody gets the same email
twice. `[:lotus, :delivery, :start | :stop | :exception]` telemetry brackets
each delivery.

## Alerts

A query schedule with a `rule` is an alert. Each run reads one value from the
result and checks the condition; the deliveries are sent only when the
outcome changes:

```elixir
Lotus.Schedules.create_schedule(%{
  name: "Open tickets",
  query_id: query.id,
  cron: "*/15 * * * *",
  rule: %{condition: "above", column: "open", threshold: 500},
  deliveries: [
    %{channel: "webhook", format: "json", config: %{"url" => "https://hooks.example.com/lotus"}}
  ]
})
```

- `"above"`, `"below"` and `"equals"` compare a number with `threshold`: the
  `column` of the first row, or the number of rows without a `column`.
- `"any_rows"` and `"no_rows"` hold when the query returns rows, or none.

When the condition starts holding the status goes from `"ok"` to `"firing"`
and the deliveries are sent. While it holds, runs send nothing. When it stops
holding the status goes back to `"ok"` and the deliveries are sent again,
unless the rule has `notify_recovery: false`. A new alert, or one whose rule
changed, starts from `"ok"`.

The schedule's `state` keeps the `"status"`, the last `"value"`, and when it
last fired and recovered. A run that cannot read the value (the query fails,
the column is missing, the value is not a number) fails as any run does and
records the error in `state`, but leaves the status as it was: one bad run
does not send a recovery and then a new alert. A run whose deliveries fail
does not change the state either, so the retry, or the next run, sends the
change again.

Deliveries get the change as `alert` on `Lotus.Delivery.Content`: the status,
the value and a sentence such as `"open is 512, above 500"`. The `"json"`
format and the webhook include it as `"alert"`, and the `"html"` format says
it above the tables. Alert runs read fresh data, as every run does.

### More conditions

Lotus Pro or your app adds conditions by name, such as one that fires when a
value moves by more than a share since the last run. A condition implements
`Lotus.Schedules.Alert.Condition` (`validate/1`, `evaluate/3`, `describe/3`)
and is registered in the config:

```elixir
config :lotus, alerts: [conditions: %{"change" => MyApp.Alerts.Change}]
```

A rule names it as its `condition` and keeps its settings in `options`:

```elixir
rule: %{condition: "change", column: "revenue", options: %{"percent" => 20}}
```

It is checked when the schedule is saved, and on each run it gets the
result and the schedule's `state`, with the last run's `"value"`. The
status, the deliveries and the errors work as for the built-in conditions.

## Observing runs

`[:lotus, :schedule, :run, :start | :stop | :exception]` telemetry brackets
every run, with the schedule and the run as recorded; the query or dashboard
it runs emits its usual run events too. See `Lotus.Telemetry`.
