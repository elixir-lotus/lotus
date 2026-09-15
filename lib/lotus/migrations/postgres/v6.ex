defmodule Lotus.Migrations.Postgres.V6 do
  @moduledoc """
  Add `source_query_id` and `depends_on_filter_id` to `lotus_dashboard_filters`.

  A filter with a `source_query_id` gets its select options from that saved
  query. A filter with a `depends_on_filter_id` passes the value of that other
  filter to its source query, so the options of one filter can depend on the
  value of another.

  Both columns are nullable, and a delete of the referenced query or filter sets
  them to `NULL`. Every existing row keeps its static options, so there is no
  backfill.
  """

  use Ecto.Migration

  def up(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    alter table(:lotus_dashboard_filters, table_opts) do
      add(:source_query_id, references(:lotus_queries, type: :integer, on_delete: :nilify_all))

      add(
        :depends_on_filter_id,
        references(:lotus_dashboard_filters, type: :integer, on_delete: :nilify_all)
      )
    end

    create_if_not_exists(index(:lotus_dashboard_filters, [:source_query_id], table_opts))
    create_if_not_exists(index(:lotus_dashboard_filters, [:depends_on_filter_id], table_opts))
  end

  def down(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    drop_if_exists(index(:lotus_dashboard_filters, [:depends_on_filter_id], table_opts))
    drop_if_exists(index(:lotus_dashboard_filters, [:source_query_id], table_opts))

    alter table(:lotus_dashboard_filters, table_opts) do
      remove(:depends_on_filter_id)
      remove(:source_query_id)
    end
  end
end
