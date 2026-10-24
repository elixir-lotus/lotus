defmodule Lotus.Migrations.Postgres.V7 do
  @moduledoc """
  Add `owner_id` and `tenant_id` to `lotus_queries` and `lotus_dashboards`,
  and make names unique per tenant.

  Both columns are nullable strings holding ids the host supplies. Lotus
  stores them and filters lists by them; it never sets them itself. Every
  existing row keeps `NULL` in both, so there is no backfill.

  A name was unique across the table. It is now unique within a tenant:
  `lotus_queries_name_index` covers the rows without a tenant (`WHERE
  tenant_id IS NULL`) and `lotus_queries_tenant_id_name_index` the rows of
  each tenant. The same goes for `lotus_dashboards`. Rolling back restores the
  table-wide index, and fails if two tenants hold the same name.
  """

  use Ecto.Migration

  @tables [:lotus_queries, :lotus_dashboards]

  def up(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    for table <- @tables do
      alter table(table, table_opts) do
        add(:owner_id, :string)
        add(:tenant_id, :string)
      end

      drop_if_exists(index(table, [:name], [name: "#{table}_name_index"] ++ table_opts))

      create(
        unique_index(
          table,
          [:name],
          [name: "#{table}_name_index", where: "tenant_id IS NULL"] ++ table_opts
        )
      )

      create(
        unique_index(
          table,
          [:tenant_id, :name],
          [name: "#{table}_tenant_id_name_index"] ++ table_opts
        )
      )

      create(index(table, [:owner_id], table_opts))
    end
  end

  def down(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    for table <- @tables do
      drop_if_exists(index(table, [:owner_id], table_opts))

      drop_if_exists(
        index(table, [:tenant_id, :name], [name: "#{table}_tenant_id_name_index"] ++ table_opts)
      )

      drop_if_exists(index(table, [:name], [name: "#{table}_name_index"] ++ table_opts))

      alter table(table, table_opts) do
        remove(:tenant_id)
        remove(:owner_id)
      end

      create(unique_index(table, [:name], [name: "#{table}_name_index"] ++ table_opts))
    end
  end
end
