defmodule Lotus.Storage.ScheduleRun do
  @moduledoc """
  One run of a schedule, for one slot (`scheduled_for`). The row is inserted
  when a node claims the slot, so a schedule and a slot have one run however
  many nodes tick.

  `status` is `"pending"` once claimed, `"running"` while it runs, then
  `"succeeded"` or `"failed"` with the `error`. `row_count` is the rows the
  query returned, or those of every query card of a dashboard.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lotus.Storage.Schedule

  @statuses ~w(pending running succeeded failed)

  @type status :: String.t()
  @type t :: %__MODULE__{
          id: term(),
          schedule_id: term(),
          scheduled_for: DateTime.t(),
          status: status(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          row_count: non_neg_integer() | nil,
          error: String.t() | nil,
          details: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  json_encoder = Lotus.JSON.encoder()

  @derive {json_encoder,
           only: [
             :id,
             :schedule_id,
             :scheduled_for,
             :status,
             :started_at,
             :finished_at,
             :row_count,
             :error,
             :details,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_schedule_runs" do
    field(:scheduled_for, :utc_datetime_usec)
    field(:status, :string, default: "pending")
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:row_count, :integer)
    field(:error, :string)
    field(:details, :map, default: %{})

    belongs_to(:schedule, Schedule)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def claim_changeset(schedule_id, scheduled_for) do
    %__MODULE__{}
    |> change(schedule_id: schedule_id, scheduled_for: scheduled_for, status: "pending")
    |> unique_constraint([:schedule_id, :scheduled_for], name: "lotus_schedule_runs_slot_index")
  end

  @doc false
  def update_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :started_at, :finished_at, :row_count, :error, :details])
    |> validate_inclusion(:status, @statuses)
  end
end
