defmodule Lotus.Storage.ScheduleRule do
  @moduledoc """
  The alert rule of a schedule: a condition on one value of the query's
  result. See `Lotus.Schedules.Alert`.

    * `:condition` - `"above"`, `"below"` or `"equals"` `:threshold`, or
      `"any_rows"` / `"no_rows"`, or one registered by name
      (`Lotus.Schedules.Alert.Condition`)
    * `:column` - The column of the first row the value is read from. Without
      one, the value is the number of rows. Not read by `"any_rows"` and
      `"no_rows"`
    * `:threshold` - The number `"above"`, `"below"` and `"equals"` compare
      the value with
    * `:notify_recovery` - Whether the deliveries are sent when the condition
      stops holding, too (default `true`)
    * `:options` - The settings of a registered condition (default `%{}`)
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lotus.Schedules.Alert

  @compared ~w(above below equals)

  @type t :: %__MODULE__{
          condition: String.t(),
          column: String.t() | nil,
          threshold: Decimal.t() | nil,
          notify_recovery: boolean(),
          options: map()
        }

  @primary_key false

  json_encoder = Lotus.JSON.encoder()
  @derive {json_encoder, only: [:condition, :column, :threshold, :notify_recovery, :options]}

  embedded_schema do
    field(:condition, :string)
    field(:column, :string)
    field(:threshold, :decimal)
    field(:notify_recovery, :boolean, default: true)
    field(:options, :map, default: %{})
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:condition, :column, :threshold, :notify_recovery, :options])
    |> validate_required([:condition])
    |> validate_inclusion(:condition, Alert.conditions())
    |> validate_condition()
  end

  # A built-in comparison needs its threshold; a registered condition checks
  # its own settings.
  defp validate_condition(%{valid?: false} = changeset), do: changeset

  defp validate_condition(changeset) do
    condition = get_field(changeset, :condition)

    case Alert.registered(condition) do
      nil when condition in @compared ->
        validate_required(changeset, [:threshold])

      nil ->
        changeset

      module ->
        case module.validate(apply_changes(changeset)) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, :options, message)
        end
    end
  end
end
