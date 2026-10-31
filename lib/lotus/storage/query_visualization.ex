defmodule Lotus.Storage.QueryVisualization do
  @moduledoc """
  Represents a saved visualization configuration for a Lotus query.

  The `config` field stores an opaque map that Lotus does not validate beyond
  ensuring it is a map with string keys. Consumers (e.g., Lotus Web) are
  responsible for validating the config according to their chosen charting library.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lotus.Storage.Query

  @type t :: %__MODULE__{
          id: term(),
          query_id: term(),
          name: String.t(),
          position: non_neg_integer(),
          config: map(),
          version: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  json_encoder = Lotus.JSON.encoder()

  @derive {json_encoder,
           only: [
             :id,
             :query_id,
             :name,
             :position,
             :config,
             :version,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_query_visualizations" do
    field(:name, :string)
    field(:position, :integer)
    field(:config, :map)
    field(:version, :integer, default: 1)

    belongs_to(:query, Query, references: :id, type: :id)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(query_id name position config)a
  @permitted @required ++ ~w(version)a

  def new(attrs), do: changeset(%__MODULE__{}, attrs)

  # A visualization stays on its query.
  def update(viz, attrs), do: changeset(viz, attrs, @permitted -- [:query_id])

  def changeset(viz, attrs, permitted \\ @permitted) do
    viz
    |> cast(attrs, permitted)
    |> normalize_config()
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:name,
      name: "lotus_query_visualizations_query_id_name_index",
      message: "name must be unique within the query"
    )
  end

  defp normalize_config(%Ecto.Changeset{} = cs) do
    case get_change(cs, :config) do
      nil -> cs
      cfg when is_map(cfg) -> put_change(cs, :config, stringify_keys(cfg))
      _ -> cs
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
