defmodule Lotus.Storage.DashboardCard do
  @moduledoc """
  Represents a card within a Lotus dashboard.

  Cards can be one of several types:
  - `:query` - Displays results from a saved query with optional visualization
  - `:text` - Displays markdown text content
  - `:link` - Displays a clickable link
  - `:heading` - Displays a section heading

  Each card has a layout that determines its position and size in the dashboard's
  12-column grid system.
  """

  use Ecto.Schema
  import Ecto.Changeset

  import Lotus.Helpers, only: [stringify_keys: 1]

  alias Lotus.Storage.{Dashboard, DashboardCardFilterMapping, Query}

  @type t :: %__MODULE__{
          id: term(),
          card_type: :query | :text | :link | :heading,
          title: String.t() | nil,
          visualization_config: map() | nil,
          content: map(),
          position: non_neg_integer(),
          layout: __MODULE__.Layout.t() | nil,
          dashboard_id: term(),
          dashboard: Dashboard.t() | Ecto.Association.NotLoaded.t(),
          query_id: term() | nil,
          query: Query.t() | Ecto.Association.NotLoaded.t() | nil,
          filter_mappings: [DashboardCardFilterMapping.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  json_encoder = Lotus.JSON.encoder()

  @derive {json_encoder,
           only: [
             :id,
             :card_type,
             :title,
             :visualization_config,
             :content,
             :position,
             :layout,
             :dashboard_id,
             :query_id,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_dashboard_cards" do
    field(:card_type, Ecto.Enum, values: [:query, :text, :link, :heading])
    field(:title, :string)
    field(:visualization_config, :map)
    field(:content, :map, default: %{})
    field(:position, :integer)

    embeds_one :layout, Layout, on_replace: :update, primary_key: false do
      @moduledoc """
      Embedded schema for card layout in the dashboard grid.

      The dashboard uses a 12-column grid system:
      - `x` - Column position (0-11)
      - `y` - Row position (0+)
      - `w` - Width in columns (1-12)
      - `h` - Height in rows (minimum 1)
      - `folded` - Whether the card starts folded to its title
      - `tab` - The tab of the dashboard the card is on, by its id in the
        dashboard's `settings["tabs"]`; `nil` for the first tab
      """

      @type t :: %__MODULE__{
              x: non_neg_integer(),
              y: non_neg_integer(),
              w: pos_integer(),
              h: pos_integer(),
              folded: boolean(),
              tab: String.t() | nil
            }

      field(:x, :integer, default: 0)
      field(:y, :integer, default: 0)
      field(:w, :integer, default: 6)
      field(:h, :integer, default: 4)
      field(:folded, :boolean, default: false)
      field(:tab, :string)
    end

    belongs_to(:dashboard, Dashboard, references: :id, type: :id)
    belongs_to(:query, Query, references: :id, type: :id)

    has_many(:filter_mappings, DashboardCardFilterMapping,
      foreign_key: :card_id,
      on_delete: :delete_all
    )

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(dashboard_id card_type position)a
  @permitted ~w(dashboard_id card_type title visualization_config content position query_id)a

  def new(attrs), do: changeset(%__MODULE__{}, attrs)
  def update(card, attrs), do: changeset(card, attrs)

  def changeset(card, attrs) do
    card
    |> cast(attrs, @permitted)
    |> cast_embed(:layout, with: &layout_changeset/2)
    |> normalize_visualization_config()
    |> normalize_content()
    |> ensure_content_default()
    |> validate_required(@required)
    |> validate_length(:title, max: 255)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_card_type()
    |> foreign_key_constraint(:dashboard_id)
    |> foreign_key_constraint(:query_id)
  end

  # Ensure content always has a value (for NOT NULL constraint)
  defp ensure_content_default(changeset) do
    case get_field(changeset, :content) do
      nil -> put_change(changeset, :content, %{})
      _ -> changeset
    end
  end

  defp layout_changeset(layout, attrs) do
    layout
    |> cast(attrs, [:x, :y, :w, :h, :folded, :tab])
    |> validate_number(:x, greater_than_or_equal_to: 0, less_than: 12)
    |> validate_number(:y, greater_than_or_equal_to: 0)
    |> validate_number(:w, greater_than: 0, less_than_or_equal_to: 12)
    |> validate_number(:h, greater_than: 0)
    |> validate_layout_bounds()
  end

  defp validate_layout_bounds(changeset) do
    x = get_field(changeset, :x) || 0
    w = get_field(changeset, :w) || 6

    if x + w > 12 do
      add_error(changeset, :w, "card extends beyond grid (x + w must be <= 12)")
    else
      changeset
    end
  end

  defp normalize_visualization_config(%Ecto.Changeset{} = cs) do
    case get_change(cs, :visualization_config) do
      nil -> cs
      cfg when is_map(cfg) -> put_change(cs, :visualization_config, stringify_keys(cfg))
      _ -> cs
    end
  end

  defp normalize_content(%Ecto.Changeset{} = cs) do
    case get_change(cs, :content) do
      nil -> cs
      content when is_map(content) -> put_change(cs, :content, stringify_keys(content))
      _ -> cs
    end
  end

  defp validate_card_type(changeset) do
    card_type = get_field(changeset, :card_type)
    query_id = get_field(changeset, :query_id)

    cond do
      card_type == :query and is_nil(query_id) ->
        add_error(changeset, :query_id, "is required for query cards")

      card_type in [:text, :link, :heading] and not is_nil(query_id) ->
        add_error(changeset, :query_id, "must be nil for non-query cards")

      true ->
        changeset
    end
  end
end
