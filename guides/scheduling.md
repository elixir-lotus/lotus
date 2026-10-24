# Scheduling

A schedule runs a saved query or a dashboard on a cron expression, in a time
zone, once per cluster. Every run is recorded. A run reads fresh data and,
when a cache is configured, leaves the cache warm, so a heavy dashboard
scheduled at 07:30 opens instantly at 08:00.

Delivering the result somewhere (a webhook, an email) and alerting on it build
on schedules and come next.

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

## Observing runs

`[:lotus, :schedule, :run, :start | :stop | :exception]` telemetry brackets
every run, with the schedule and the run as recorded; the query or dashboard
it runs emits its usual run events too. See `Lotus.Telemetry`.
