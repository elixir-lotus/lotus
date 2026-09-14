defmodule Lotus.Storage.DashboardCardFilterMapping do
  @moduledoc """
  Maps a dashboard filter to a query variable within a card.

  This schema establishes the connection between a dashboard-level filter and
  the query variable it controls within a specific card. When the filter value
  changes, it is passed to the query as the specified variable.

  ## Transform

  The optional `transform` field changes the filter value before the query
  variable gets it. Lotus has two transforms, for a date range value in the
  form `"start,end"`:

  - `"date_range_start"` - keeps the part before the comma
  - `"date_range_end"` - keeps the part after the comma. A value with no comma
    does not change

  Any other transform does not change the value.

  The transform gets the value after `Lotus.Dashboards.DateToken` resolves a
  relative date token, so a `:date_range` filter with the value
  `"last_7_days"` can map its start and end dates to two variables.

  Example transform config:
  ```json
  {
    "type": "date_range_start"
  }
  ```
  """

  use Ecto.Schema
  import Ecto.Changeset

  import Lotus.Helpers, only: [stringify_keys: 1]

  alias Lotus.Storage.{DashboardCard, DashboardFilter}

  @type t :: %__MODULE__{
          id: term(),
          variable_name: String.t(),
          transform: map() | nil,
          card_id: term(),
          card: DashboardCard.t() | Ecto.Association.NotLoaded.t(),
          filter_id: term(),
          filter: DashboardFilter.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  json_encoder = Lotus.JSON.encoder()

  @derive {json_encoder,
           only: [
             :id,
             :variable_name,
             :transform,
             :card_id,
             :filter_id,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_dashboard_card_filter_mappings" do
    field(:variable_name, :string)
    field(:transform, :map)

    belongs_to(:card, DashboardCard, references: :id, type: :id)
    belongs_to(:filter, DashboardFilter, references: :id, type: :id)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(card_id filter_id variable_name)a
  @permitted ~w(card_id filter_id variable_name transform)a

  def new(attrs), do: changeset(%__MODULE__{}, attrs)
  def update(mapping, attrs), do: changeset(mapping, attrs)

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, @permitted)
    |> normalize_transform()
    |> validate_required(@required)
    |> validate_length(:variable_name, min: 1, max: 255)
    |> validate_format(:variable_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/,
      message: "must be a valid variable name"
    )
    |> unique_constraint([:card_id, :filter_id, :variable_name],
      name: "lotus_dashboard_card_filter_mappings_card_filter_variable_index",
      message: "this filter is already mapped to this variable for this card"
    )
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:filter_id)
  end

  defp normalize_transform(%Ecto.Changeset{} = cs) do
    case get_change(cs, :transform) do
      nil -> cs
      transform when is_map(transform) -> put_change(cs, :transform, stringify_keys(transform))
      _ -> cs
    end
  end
end
