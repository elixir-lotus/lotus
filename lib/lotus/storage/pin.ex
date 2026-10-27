defmodule Lotus.Storage.Pin do
  @moduledoc """
  A result a person keeps beside their next runs of a query, to compare
  them (see `Lotus.Pins`).

  It is the statement that ran, with its `data_source`, `search_path` and
  `vars`, the editor's `text` then (to put back), and the `result` it
  showed: `"columns"`, `"rows"` (as text, as they were shown), `"num_rows"`,
  `"total_count"` when the source counted it, and `"duration_ms"`.

  One per person (`owner_id`) and query (`query_id`, `nil` for a query not
  saved yet), within a `tenant_id` when there is one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lotus.Storage.Query

  @type t :: %__MODULE__{
          id: term(),
          query_id: term() | nil,
          owner_id: String.t() | nil,
          tenant_id: String.t() | nil,
          data_source: String.t() | nil,
          search_path: String.t() | nil,
          statement: String.t(),
          text: String.t() | nil,
          vars: map(),
          result: map(),
          pinned_at: DateTime.t(),
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
             :data_source,
             :search_path,
             :statement,
             :text,
             :vars,
             :result,
             :pinned_at
           ]}

  schema "lotus_pins" do
    field(:owner_id, :string)
    field(:tenant_id, :string)
    field(:data_source, :string)
    field(:search_path, :string)
    field(:statement, :string)
    field(:text, :string)
    field(:vars, :map, default: %{})
    field(:result, :map, default: %{})
    field(:pinned_at, :utc_datetime_usec)

    belongs_to(:query, Query)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [
      :query_id,
      :data_source,
      :search_path,
      :statement,
      :text,
      :vars,
      :result,
      :pinned_at
    ])
    |> validate_required([:statement, :pinned_at])
    |> foreign_key_constraint(:query_id)
  end
end
