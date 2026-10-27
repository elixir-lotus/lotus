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

  It also adds `lotus_schedules` and `lotus_schedule_runs`. A schedule runs a
  saved query or a dashboard on a cron expression in a time zone (see
  `Lotus.Schedules`). Each run is a row in `lotus_schedule_runs`, unique per
  schedule and slot (`scheduled_for`): inserting it is how one node of a
  cluster claims the slot, so a slot runs once however many nodes tick.
  `deliveries`, `rule` and `state` are read by delivery and alerts, which
  build on schedules; a schedule without them only runs.
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

    create_if_not_exists table(:lotus_schedules, [primary_key: false] ++ table_opts) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, null: false)
      add(:query_id, references(:lotus_queries, type: :integer, on_delete: :delete_all))

      add(
        :dashboard_id,
        references(:lotus_dashboards, type: :integer, on_delete: :delete_all)
      )

      add(:cron, :string, null: false)
      add(:time_zone, :string, null: false, default: "Etc/UTC")
      add(:enabled, :boolean, null: false, default: true)
      add(:params, :map, null: false, default: "{}")
      add(:deliveries, :map, null: false, default: "[]")
      add(:rule, :map)
      add(:state, :map, null: false, default: "{}")
      add(:next_run_at, :utc_datetime_usec)
      add(:last_run_at, :utc_datetime_usec)
      add(:owner_id, :string)
      add(:tenant_id, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:lotus_schedules, [:enabled, :next_run_at], table_opts))
    create_if_not_exists(index(:lotus_schedules, [:query_id], table_opts))
    create_if_not_exists(index(:lotus_schedules, [:dashboard_id], table_opts))
    create_if_not_exists(index(:lotus_schedules, [:tenant_id, :owner_id], table_opts))

    create_if_not_exists table(:lotus_schedule_runs, [primary_key: false] ++ table_opts) do
      add(:id, :serial, primary_key: true)

      add(:schedule_id, references(:lotus_schedules, type: :integer, on_delete: :delete_all),
        null: false
      )

      add(:scheduled_for, :utc_datetime_usec, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:row_count, :integer)
      add(:error, :text)
      add(:details, :map, null: false, default: "{}")
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(
        :lotus_schedule_runs,
        [:schedule_id, :scheduled_for],
        [name: "lotus_schedule_runs_slot_index"] ++ table_opts
      )
    )

    create_if_not_exists(index(:lotus_schedule_runs, [:status], table_opts))
  end

  def down(opts \\ %{}) do
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    drop_if_exists(table(:lotus_schedule_runs, table_opts))
    drop_if_exists(table(:lotus_schedules, table_opts))

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
