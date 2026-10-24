defmodule Lotus.Schedules do
  @moduledoc """
  Schedules: a saved query or a dashboard run on a cron expression, in a time
  zone, once per cluster.

      {:ok, schedule} =
        Lotus.Schedules.create_schedule(%{
          name: "Weekly revenue",
          dashboard_id: dashboard.id,
          cron: "0 8 * * MON",
          time_zone: "Europe/Lisbon"
        })

  `cron` is the five standard fields, read as the wall clock of `time_zone`,
  so the schedule above runs at 08:00 Lisbon time all year, through daylight
  saving. See `Lotus.Schedules.Cron` for the days the clock changes.

  `params` are the variables of a query (`"min_age" => 30`) or the filter
  values of a dashboard, as `Lotus.run_query/2` and `Lotus.run_dashboard/2`
  take them.

  ## Running

  Nothing runs until the host turns the scheduler on:

      config :lotus, scheduler: [enabled: true]

  `Lotus.Scheduler` then looks for due schedules every 30 seconds
  (`:interval`) on every node that has it enabled. A node claims a due run by
  inserting its row in `lotus_schedule_runs`, which is unique per schedule
  and slot, so each slot runs once however many nodes look. The run is then
  performed by the `:executor` (`Lotus.Scheduler.Executors.Inline` by
  default). A schedule whose slots were missed while no node ran it runs
  once, for the latest of them, and goes on from the next one.

  A run goes through `Lotus.run_query/2` or `Lotus.run_dashboard/2` like any
  other, so visibility, middleware and session settings apply, and with
  `cache: :refresh` when a cache is configured: it reads fresh data and
  leaves the cache warm. It has no actor unless the `:actor` callback of the
  scheduler config gives one; see `Lotus.Scheduler.Worker`.

  Each run is recorded in `lotus_schedule_runs` (`list_runs/2`). A
  schedule's `deliveries` send each successful run somewhere; see
  `Lotus.Delivery`. A query schedule with a `rule` is an alert, which sends
  only when the rule's status changes; see `Lotus.Schedules.Alert`.

  ## Content changes

  Creating, updating and deleting a schedule fire `:before_content_change`
  and `:after_content_change` with resource `:schedule`, and take `:context`
  in `opts`, as the other content does. A schedule has an `owner_id` and a
  `tenant_id`, set from the options of `create_schedule/2` and
  `update_schedule/3` as on queries (see "Owner and tenant" in
  `Lotus.Storage`); Lotus stores and filters by them only.
  """

  import Ecto.Query

  alias Lotus.Schedules.Cron
  alias Lotus.Storage.{Mutation, Ownership, Schedule, ScheduleRun}

  @type id :: integer() | binary()

  @doc """
  Lists schedules.

  ## Options

    * `:query_id`, `:dashboard_id` - The schedules of this query or dashboard
    * `:enabled` - Only the enabled (`true`) or disabled (`false`) schedules
    * `:owner_id`, `:tenant_id` - As in `Lotus.Storage.list_queries_by/1`
  """
  @spec list_schedules(keyword()) :: [Schedule.t()]
  def list_schedules(opts \\ []) do
    Schedule
    |> Ownership.filter(opts)
    |> filter_by(:query_id, opts)
    |> filter_by(:dashboard_id, opts)
    |> filter_by(:enabled, opts)
    |> order_by([s], asc: s.name, asc: s.id)
    |> Lotus.repo().all()
  end

  defp filter_by(query, field, opts) do
    case Keyword.fetch(opts, field) do
      {:ok, value} -> where(query, [s], field(s, ^field) == ^value)
      :error -> query
    end
  end

  @doc "Gets a schedule by id, or `nil`."
  @spec get_schedule(id()) :: Schedule.t() | nil
  def get_schedule(id), do: Lotus.repo().get(Schedule, id)

  @doc "Gets a schedule by id. Raises `Ecto.NoResultsError` if there is none."
  @spec get_schedule!(id()) :: Schedule.t()
  def get_schedule!(id), do: Lotus.repo().get!(Schedule, id)

  @doc """
  Creates a schedule, due at its next run from now.

  Takes `:context`, `:owner_id` and `:tenant_id` in `opts`.
  """
  @spec create_schedule(map(), keyword()) ::
          {:ok, Schedule.t()} | {:error, Ecto.Changeset.t() | Lotus.Middleware.halted()}
  def create_schedule(attrs, opts \\ []) do
    %Schedule{}
    |> Schedule.changeset(attrs)
    |> Ownership.put(opts)
    |> put_next_run(DateTime.utc_now())
    |> Mutation.run(:create, :schedule, opts)
  end

  @doc """
  Updates a schedule. A change of its cron expression, its time zone or of
  `enabled` moves its next run; a disabled schedule has none.
  """
  @spec update_schedule(Schedule.t(), map(), keyword()) ::
          {:ok, Schedule.t()} | {:error, Ecto.Changeset.t() | Lotus.Middleware.halted()}
  def update_schedule(%Schedule{} = schedule, attrs, opts \\ []) do
    changeset =
      schedule
      |> Schedule.changeset(attrs)
      |> Ownership.put(opts)

    changeset =
      if Enum.any?([:cron, :time_zone, :enabled], &Map.has_key?(changeset.changes, &1)),
        do: put_next_run(changeset, DateTime.utc_now()),
        else: changeset

    Mutation.run(changeset, :update, :schedule, opts)
  end

  @doc "Deletes a schedule and its runs."
  @spec delete_schedule(Schedule.t() | id(), keyword()) ::
          {:ok, Schedule.t()} | {:error, term()}
  def delete_schedule(schedule_or_id, opts \\ [])

  def delete_schedule(%Schedule{} = schedule, opts),
    do: Mutation.run(schedule, :delete, :schedule, opts)

  def delete_schedule(id, opts) do
    case get_schedule(id) do
      nil -> {:error, :not_found}
      schedule -> delete_schedule(schedule, opts)
    end
  end

  @doc """
  The runs of a schedule, the latest first.

  ## Options

    * `:limit` - How many (default 50)
    * `:status` - Only the runs with this status
  """
  @spec list_runs(Schedule.t() | id(), keyword()) :: [ScheduleRun.t()]
  def list_runs(schedule_or_id, opts \\ [])

  def list_runs(%Schedule{id: id}, opts), do: list_runs(id, opts)

  def list_runs(schedule_id, opts) do
    query =
      from(r in ScheduleRun,
        where: r.schedule_id == ^schedule_id,
        order_by: [desc: r.scheduled_for, desc: r.id],
        limit: ^Keyword.get(opts, :limit, 50)
      )

    query =
      case Keyword.fetch(opts, :status) do
        {:ok, status} -> where(query, [r], r.status == ^status)
        :error -> query
      end

    Lotus.repo().all(query)
  end

  @doc """
  The next run of `schedule` strictly after `from`, in UTC, or `nil` for a
  disabled schedule.
  """
  @spec next_run(Schedule.t(), DateTime.t()) :: DateTime.t() | nil
  def next_run(%Schedule{enabled: false}, _from), do: nil

  def next_run(%Schedule{cron: cron, time_zone: time_zone}, %DateTime{} = from) do
    case Cron.next_run(cron, time_zone, from) do
      {:ok, at} -> at
      {:error, _reason} -> nil
    end
  end

  defp put_next_run(%Ecto.Changeset{valid?: false} = changeset, _now), do: changeset

  defp put_next_run(changeset, now) do
    schedule = Ecto.Changeset.apply_changes(changeset)
    Ecto.Changeset.put_change(changeset, :next_run_at, next_run(schedule, now))
  end
end
