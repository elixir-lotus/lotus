defmodule Lotus.Storage.Schedule do
  @moduledoc """
  A schedule: a saved query or a dashboard run on a cron expression in a time
  zone. See `Lotus.Schedules`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lotus.Schedules.Cron
  alias Lotus.Storage.{Dashboard, Query, ScheduleRun}

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          query_id: term() | nil,
          dashboard_id: term() | nil,
          cron: String.t(),
          time_zone: String.t(),
          enabled: boolean(),
          params: map(),
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
             :cron,
             :time_zone,
             :enabled,
             :params,
             :next_run_at,
             :last_run_at,
             :owner_id,
             :tenant_id,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_schedules" do
    field(:name, :string)
    field(:cron, :string)
    field(:time_zone, :string, default: "Etc/UTC")
    field(:enabled, :boolean, default: true)
    field(:params, :map, default: %{})
    field(:next_run_at, :utc_datetime_usec)
    field(:last_run_at, :utc_datetime_usec)
    field(:owner_id, :string)
    field(:tenant_id, :string)

    belongs_to(:query, Query)
    belongs_to(:dashboard, Dashboard)
    has_many(:runs, ScheduleRun)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name cron)a
  @permitted ~w(name query_id dashboard_id cron time_zone enabled params)a

  @doc false
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_target()
    |> validate_cron()
    |> validate_time_zone()
    |> foreign_key_constraint(:query_id)
    |> foreign_key_constraint(:dashboard_id)
  end

  # A schedule runs exactly one thing: a query or a dashboard.
  defp validate_target(changeset) do
    case {get_field(changeset, :query_id), get_field(changeset, :dashboard_id)} do
      {nil, nil} ->
        add_error(changeset, :query_id, "a query or a dashboard is required")

      {_query, nil} ->
        changeset

      {nil, _dashboard} ->
        changeset

      {_query, _dashboard} ->
        add_error(changeset, :dashboard_id, "a schedule runs a query or a dashboard, not both")
    end
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
