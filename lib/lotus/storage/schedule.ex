defmodule Lotus.Storage.Schedule do
  @moduledoc """
  A schedule: a saved query, a dashboard, or a target an extension registers
  (`target_type` and `target_id`, `Lotus.Schedules.Target`) run on a cron
  expression in a time zone. See `Lotus.Schedules`.

  A query or target schedule with a `rule` is an alert, and keeps its
  status in `state`; see `Lotus.Schedules.Alert`. `state` is written by the
  runs only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lotus.Schedules.{Cron, Targets}
  alias Lotus.Storage.{Dashboard, Query, ScheduleDelivery, ScheduleRule, ScheduleRun}

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          query_id: term() | nil,
          dashboard_id: term() | nil,
          target_type: String.t() | nil,
          target_id: String.t() | nil,
          cron: String.t(),
          time_zone: String.t(),
          enabled: boolean(),
          params: map(),
          deliveries: [ScheduleDelivery.t()],
          rule: ScheduleRule.t() | nil,
          state: map(),
          next_run_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          owner_id: String.t() | nil,
          tenant_id: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  json_encoder = Lotus.JSON.encoder()

  @derive {json_encoder,
           only: [
             :id,
             :name,
             :query_id,
             :dashboard_id,
             :target_type,
             :target_id,
             :cron,
             :time_zone,
             :enabled,
             :params,
             :deliveries,
             :rule,
             :state,
             :next_run_at,
             :last_run_at,
             :owner_id,
             :tenant_id,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_schedules" do
    field(:name, :string)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:cron, :string)
    field(:time_zone, :string, default: "Etc/UTC")
    field(:enabled, :boolean, default: true)
    field(:params, :map, default: %{})
    field(:next_run_at, :utc_datetime_usec)
    field(:last_run_at, :utc_datetime_usec)
    field(:owner_id, :string)
    field(:tenant_id, :string)
    field(:state, :map, default: %{})

    embeds_many(:deliveries, ScheduleDelivery, on_replace: :delete)
    embeds_one(:rule, ScheduleRule, on_replace: :delete)

    belongs_to(:query, Query)
    belongs_to(:dashboard, Dashboard)
    has_many(:runs, ScheduleRun)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name cron)a
  @permitted ~w(name query_id dashboard_id target_type target_id cron time_zone enabled params)a

  @doc false
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, @permitted)
    |> cast_embed(:deliveries, with: &ScheduleDelivery.changeset/2)
    |> cast_embed(:rule, with: &ScheduleRule.changeset/2)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_target()
    |> validate_cron()
    |> validate_time_zone()
    |> validate_rule()
    |> foreign_key_constraint(:query_id)
    |> foreign_key_constraint(:dashboard_id)
  end

  # A schedule runs exactly one thing: a query, a dashboard, or a target of
  # a registered type.
  defp validate_target(changeset) do
    target = get_field(changeset, :target_type)

    case Enum.reject(
           [
             get_field(changeset, :query_id),
             get_field(changeset, :dashboard_id),
             target
           ],
           &is_nil/1
         ) do
      [] ->
        add_error(changeset, :query_id, "a query or a dashboard is required")

      [_one] when is_nil(target) ->
        changeset

      [_one] ->
        validate_target_type(changeset, target)

      _many ->
        add_error(changeset, :dashboard_id, "a schedule runs one query, dashboard or target")
    end
  end

  defp validate_target_type(changeset, type) do
    cond do
      not Map.has_key?(Targets.all(), type) ->
        add_error(changeset, :target_type, "is not a known target: #{inspect(type)}")

      get_field(changeset, :target_id) in [nil, ""] ->
        add_error(changeset, :target_id, "can't be blank")

      true ->
        changeset
    end
  end

  # An alert reads a value from one result, so it watches a query. A new
  # rule starts from "ok".
  defp validate_rule(changeset) do
    changeset =
      if get_field(changeset, :rule) && get_field(changeset, :dashboard_id),
        do: add_error(changeset, :rule, "an alert watches a query, not a dashboard"),
        else: changeset

    if Map.has_key?(changeset.changes, :rule),
      do: put_change(changeset, :state, %{}),
      else: changeset
  end

  defp validate_cron(changeset) do
    validate_change(changeset, :cron, fn :cron, cron ->
      case Cron.parse(cron) do
        {:ok, _expression} -> []
        {:error, message} -> [cron: "is not a cron expression: #{message}"]
      end
    end)
  end

  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, time_zone ->
      if Cron.valid_time_zone?(time_zone), do: [], else: [time_zone: "is not a known time zone"]
    end)
  end
end
