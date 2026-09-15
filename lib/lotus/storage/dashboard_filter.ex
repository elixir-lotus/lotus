defmodule Lotus.Storage.DashboardFilter do
  @moduledoc """
  Represents a filter control for a Lotus dashboard.

  Dashboard filters are input controls displayed at the top of a dashboard that
  allow users to filter data across multiple cards. Each filter can be mapped to
  one or more query variables in the dashboard's cards.

  ## Filter Types

  - `:text` - Free-form text input
  - `:number` - Numeric input
  - `:date` - Single date selection
  - `:date_range` - Date range selection (start/end)
  - `:select` - Dropdown selection

  ## Widgets

  - `:input` - Standard text/number input field
  - `:select` - Dropdown select
  - `:date_picker` - Date picker calendar
  - `:date_range_picker` - Date range picker with start/end

  The `config` field stores widget-specific configuration like select options,
  date formats, or validation rules.

  ## Relative Date Tokens

  The `default_value` of a `:date_range` filter can be a relative date token
  such as `"last_30_days"`, and the `default_value` of a `:date` filter can be
  `"today"` or `"yesterday"`. The token resolves each time a card runs, see
  `Lotus.Dashboards.DateToken`. The changeset does not accept a range token as
  the `default_value` of a `:date` filter.

  ## Cascading Filters

  A filter with the `:select` widget can get its options from a saved query in
  `source_query_id`. With `depends_on_filter_id`, the value of that other filter
  of the same dashboard goes to the source query as the variable named after
  the other filter's `name`. A `city` filter that depends on a `country` filter
  can use `SELECT DISTINCT city FROM locations WHERE country = {{country}}`.
  See `Lotus.Dashboards.list_dashboard_filter_options/2`.

  A dependency needs a source query and cannot be the filter itself.
  `Lotus.Dashboards` also rejects a dependency on a filter of another dashboard
  and a dependency that makes a cycle. A delete of the source query or of the
  other filter sets the field to `nil`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  import Lotus.Helpers, only: [stringify_keys: 1]

  alias Lotus.Dashboards.DateToken
  alias Lotus.Storage.{Dashboard, DashboardCardFilterMapping, Query}

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          label: String.t(),
          filter_type: :text | :number | :date | :date_range | :select,
          widget: :input | :select | :date_picker | :date_range_picker,
          default_value: String.t() | nil,
          config: map(),
          position: non_neg_integer(),
          dashboard_id: term(),
          dashboard: Dashboard.t() | Ecto.Association.NotLoaded.t(),
          source_query_id: term() | nil,
          source_query: Query.t() | Ecto.Association.NotLoaded.t() | nil,
          depends_on_filter_id: term() | nil,
          depends_on_filter: t() | Ecto.Association.NotLoaded.t() | nil,
          dependent_filters: [t()] | Ecto.Association.NotLoaded.t(),
          card_mappings: [DashboardCardFilterMapping.t()] | Ecto.Association.NotLoaded.t(),
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
             :label,
             :filter_type,
             :widget,
             :default_value,
             :config,
             :position,
             :dashboard_id,
             :source_query_id,
             :depends_on_filter_id,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_dashboard_filters" do
    field(:name, :string)
    field(:label, :string)
    field(:filter_type, Ecto.Enum, values: [:text, :number, :date, :date_range, :select])
    field(:widget, Ecto.Enum, values: [:input, :select, :date_picker, :date_range_picker])
    field(:default_value, :string)
    field(:config, :map, default: %{})
    field(:position, :integer)

    belongs_to(:dashboard, Dashboard, references: :id, type: :id)
    belongs_to(:source_query, Query, references: :id, type: :id)
    belongs_to(:depends_on_filter, __MODULE__, references: :id, type: :id)

    has_many(:dependent_filters, __MODULE__, foreign_key: :depends_on_filter_id)

    has_many(:card_mappings, DashboardCardFilterMapping,
      foreign_key: :filter_id,
      on_delete: :delete_all
    )

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(dashboard_id name label filter_type widget position)a
  @permitted ~w(dashboard_id name label filter_type widget default_value config position
                source_query_id depends_on_filter_id)a

  def new(attrs), do: changeset(%__MODULE__{}, attrs)
  def update(filter, attrs), do: changeset(filter, attrs)

  def changeset(filter, attrs) do
    filter
    |> cast(attrs, @permitted)
    |> normalize_config()
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:label, min: 1, max: 255)
    |> validate_format(:name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/, message: "must be a valid identifier")
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_widget_type_compatibility()
    |> validate_default_value_for_filter_type()
    |> validate_source_query_needs_select_widget()
    |> validate_dependency_needs_source_query()
    |> validate_dependency_is_another_filter()
    |> unique_constraint(:name,
      name: "lotus_dashboard_filters_dashboard_id_name_index",
      message: "name must be unique within the dashboard"
    )
    |> foreign_key_constraint(:dashboard_id)
    |> foreign_key_constraint(:source_query_id)
    |> foreign_key_constraint(:depends_on_filter_id)
  end

  defp normalize_config(%Ecto.Changeset{} = cs) do
    case get_change(cs, :config) do
      nil -> cs
      config when is_map(config) -> put_change(cs, :config, stringify_keys(config))
      _ -> cs
    end
  end

  defp validate_widget_type_compatibility(changeset) do
    filter_type = get_field(changeset, :filter_type)
    widget = get_field(changeset, :widget)

    valid_combinations = %{
      text: [:input, :select],
      number: [:input, :select],
      date: [:date_picker, :input],
      date_range: [:date_range_picker],
      select: [:select]
    }

    valid_widgets = Map.get(valid_combinations, filter_type, [])

    if widget in valid_widgets do
      changeset
    else
      add_error(
        changeset,
        :widget,
        "#{widget} is not compatible with filter type #{filter_type}"
      )
    end
  end

  defp validate_source_query_needs_select_widget(changeset) do
    if get_field(changeset, :source_query_id) != nil and get_field(changeset, :widget) != :select do
      add_error(changeset, :source_query_id, "needs the select widget")
    else
      changeset
    end
  end

  defp validate_dependency_needs_source_query(changeset) do
    if (changed?(changeset, :depends_on_filter_id) or changed?(changeset, :source_query_id)) and
         get_field(changeset, :depends_on_filter_id) != nil and
         get_field(changeset, :source_query_id) == nil do
      add_error(changeset, :depends_on_filter_id, "needs a source query")
    else
      changeset
    end
  end

  defp validate_dependency_is_another_filter(%Ecto.Changeset{data: %{id: id}} = changeset) do
    if id != nil and get_field(changeset, :depends_on_filter_id) == id do
      add_error(changeset, :depends_on_filter_id, "cannot be the filter itself")
    else
      changeset
    end
  end

  defp validate_default_value_for_filter_type(changeset) do
    filter_type = get_field(changeset, :filter_type)
    default_value = get_field(changeset, :default_value)

    if filter_type == :date and default_value in DateToken.tokens() and
         not DateToken.single_day?(default_value) do
      add_error(
        changeset,
        :default_value,
        "#{default_value} is a date range token and needs filter type date_range"
      )
    else
      changeset
    end
  end
end
