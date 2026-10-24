defmodule Lotus.Storage.ScheduleRule do
  @moduledoc """
  The alert rule of a schedule: a condition on one value of the query's
  result. See `Lotus.Schedules.Alert`.

    * `:condition` - `"above"`, `"below"` or `"equals"` `:threshold`, or
      `"any_rows"` / `"no_rows"`
    * `:column` - The column of the first row the value is read from. Without
      one, the value is the number of rows. Not read by `"any_rows"` and
      `"no_rows"`
    * `:threshold` - The number `"above"`, `"below"` and `"equals"` compare
      the value with
    * `:notify_recovery` - Whether the deliveries are sent when the condition
      stops holding, too (default `true`)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @conditions ~w(above below equals any_rows no_rows)
  @compared ~w(above below equals)

  @type t :: %__MODULE__{
          condition: String.t(),
          column: String.t() | nil,
          threshold: Decimal.t() | nil,
          notify_recovery: boolean()
        }

  @primary_key false

  json_encoder = Lotus.JSON.encoder()
  @derive {json_encoder, only: [:condition, :column, :threshold, :notify_recovery]}

  embedded_schema do
    field(:condition, :string)
    field(:column, :string)
    field(:threshold, :decimal)
    field(:notify_recovery, :boolean, default: true)
  end

  @doc false
  def conditions, do: @conditions

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:condition, :column, :threshold, :notify_recovery])
    |> validate_required([:condition])
    |> validate_inclusion(:condition, @conditions)
    |> validate_threshold()
  end

  defp validate_threshold(changeset) do
    if get_field(changeset, :condition) in @compared,
      do: validate_required(changeset, [:threshold]),
      else: changeset
  end
end
