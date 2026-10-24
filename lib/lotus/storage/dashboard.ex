defmodule Lotus.Storage.Dashboard do
  @moduledoc """
  Represents a saved Lotus dashboard.

  Dashboards are collections of cards that display query results, text, links,
  or headings. They support:

  - Multiple cards arranged in a 12-column grid layout
  - Dashboard-level filters that can be mapped to query variables
  - Public sharing via unique tokens
  - Auto-refresh at configurable intervals
  """

  use Ecto.Schema
  import Ecto.Changeset

  import Lotus.Helpers, only: [stringify_keys: 1]

  alias Lotus.Storage.{DashboardCard, DashboardFilter}

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          description: String.t() | nil,
          settings: map(),
          public_token: String.t() | nil,
          auto_refresh_seconds: non_neg_integer() | nil,
          owner_id: String.t() | nil,
          tenant_id: String.t() | nil,
          cards: [DashboardCard.t()] | Ecto.Association.NotLoaded.t(),
          filters: [DashboardFilter.t()] | Ecto.Association.NotLoaded.t(),
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
             :description,
             :settings,
             :public_token,
             :auto_refresh_seconds,
             :owner_id,
             :tenant_id,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_dashboards" do
    field(:name, :string)
    field(:description, :string)
    field(:settings, :map, default: %{})
    field(:public_token, :string)
    field(:auto_refresh_seconds, :integer)
    field(:owner_id, :string)
    field(:tenant_id, :string)

    has_many(:cards, DashboardCard, on_delete: :delete_all)
    has_many(:filters, DashboardFilter, on_delete: :delete_all)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name)a
  @permitted ~w(name description settings public_token auto_refresh_seconds)a

  def new(attrs), do: changeset(%__MODULE__{}, attrs)
  def update(dashboard, attrs), do: changeset(dashboard, attrs)

  def changeset(dashboard, attrs) do
    dashboard
    |> cast(attrs, @permitted)
    |> normalize_settings()
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_auto_refresh_seconds()
    |> unique_constraint(:name, name: "lotus_dashboards_name_index")
    |> unique_constraint(:name, name: "lotus_dashboards_tenant_id_name_index")
    |> unique_constraint(:public_token, name: "lotus_dashboards_public_token_index")
  end

  defp normalize_settings(%Ecto.Changeset{} = cs) do
    case get_change(cs, :settings) do
      nil -> cs
      settings when is_map(settings) -> put_change(cs, :settings, stringify_keys(settings))
      _ -> cs
    end
  end

  defp validate_auto_refresh_seconds(changeset) do
    case get_change(changeset, :auto_refresh_seconds) do
      nil ->
        changeset

      seconds when is_integer(seconds) and seconds >= 60 and seconds <= 3600 ->
        changeset

      seconds when is_integer(seconds) ->
        add_error(changeset, :auto_refresh_seconds, "must be between 60 and 3600 seconds")

      _ ->
        add_error(changeset, :auto_refresh_seconds, "must be an integer")
    end
  end
end
