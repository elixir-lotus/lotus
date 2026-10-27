defmodule Lotus.Migrations.SQLite do
  @moduledoc false

  @behaviour Lotus.Migration

  use Ecto.Migration

  @impl Lotus.Migration
  def up(_opts \\ []) do
    ensure_data_source_column!()

    create_if_not_exists table(:lotus_queries, primary_key: false) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:statement, :text, null: false)
      add(:variables, :map, null: false, default: "[]")
      add(:data_source, :string)
      add(:search_path, :string)
      add(:query_language, :string, size: 32)
      add(:owner_id, :string)
      add(:tenant_id, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create_tenant_indexes(:lotus_queries)

    create_if_not_exists table(:lotus_query_visualizations, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:query_id, references(:lotus_queries, type: :integer, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:position, :integer, null: false)
      add(:config, :map, null: false)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:lotus_query_visualizations, [:query_id, :position]))

    create_if_not_exists(
      unique_index(:lotus_query_visualizations, [:query_id, :name],
        name: "lotus_query_visualizations_query_id_name_index"
      )
    )

    create_if_not_exists table(:lotus_dashboards, primary_key: false) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:settings, :map, null: false, default: "{}")
      add(:public_token, :string)
      add(:auto_refresh_seconds, :integer)
      add(:owner_id, :string)
      add(:tenant_id, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create_tenant_indexes(:lotus_dashboards)

    create_if_not_exists(
      unique_index(:lotus_dashboards, [:public_token],
        name: "lotus_dashboards_public_token_index"
      )
    )

    create_if_not_exists table(:lotus_dashboard_cards, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:dashboard_id, references(:lotus_dashboards, type: :integer, on_delete: :delete_all),
        null: false
      )

      add(:query_id, references(:lotus_queries, type: :integer, on_delete: :nilify_all))

      add(:card_type, :string, null: false)
      add(:title, :string)
      add(:visualization_config, :map)
      add(:content, :map, null: false, default: "{}")
      add(:position, :integer, null: false)
      add(:layout, :map, null: false, default: "{\"x\":0,\"y\":0,\"w\":6,\"h\":4}")
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:lotus_dashboard_cards, [:dashboard_id, :position]))

    create_if_not_exists table(:lotus_dashboard_filters, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:dashboard_id, references(:lotus_dashboards, type: :integer, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:label, :string, null: false)
      add(:filter_type, :string, null: false)
      add(:widget, :string, null: false)
      add(:default_value, :string)
      add(:config, :map, null: false, default: "{}")
      add(:position, :integer, null: false)
      add(:source_query_id, references(:lotus_queries, type: :integer, on_delete: :nilify_all))

      add(
        :depends_on_filter_id,
        references(:lotus_dashboard_filters, type: :integer, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:lotus_dashboard_filters, [:dashboard_id, :position]))

    create_if_not_exists(
      unique_index(:lotus_dashboard_filters, [:dashboard_id, :name],
        name: "lotus_dashboard_filters_dashboard_id_name_index"
      )
    )

    create_if_not_exists(index(:lotus_dashboard_filters, [:source_query_id]))
    create_if_not_exists(index(:lotus_dashboard_filters, [:depends_on_filter_id]))

    create_if_not_exists table(:lotus_dashboard_card_filter_mappings, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:card_id, references(:lotus_dashboard_cards, type: :integer, on_delete: :delete_all),
        null: false
      )

      add(
        :filter_id,
        references(:lotus_dashboard_filters, type: :integer, on_delete: :delete_all),
        null: false
      )

      add(:variable_name, :string, null: false)
      add(:transform, :map)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:lotus_dashboard_card_filter_mappings, [:card_id]))
    create_if_not_exists(index(:lotus_dashboard_card_filter_mappings, [:filter_id]))

    create_if_not_exists(
      unique_index(:lotus_dashboard_card_filter_mappings, [:card_id, :filter_id, :variable_name],
        name: "lotus_dashboard_card_filter_mappings_card_filter_variable_index"
      )
    )

    create_if_not_exists table(:lotus_schedules, primary_key: false) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, null: false)
      add(:query_id, references(:lotus_queries, type: :integer, on_delete: :delete_all))
      add(:dashboard_id, references(:lotus_dashboards, type: :integer, on_delete: :delete_all))
      add(:target_type, :string)
      add(:target_id, :string)
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

    create_if_not_exists(index(:lotus_schedules, [:enabled, :next_run_at]))
    create_if_not_exists(index(:lotus_schedules, [:query_id]))
    create_if_not_exists(index(:lotus_schedules, [:dashboard_id]))
    create_if_not_exists(index(:lotus_schedules, [:target_type, :target_id]))
    create_if_not_exists(index(:lotus_schedules, [:tenant_id, :owner_id]))

    create_if_not_exists table(:lotus_schedule_runs, primary_key: false) do
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
      unique_index(:lotus_schedule_runs, [:schedule_id, :scheduled_for],
        name: "lotus_schedule_runs_slot_index"
      )
    )

    create_if_not_exists(index(:lotus_schedule_runs, [:status]))

    :ok
  end

  @impl Lotus.Migration
  def down(_opts \\ []) do
    drop_if_exists(table(:lotus_schedule_runs))
    drop_if_exists(table(:lotus_schedules))

    drop_if_exists(
      index(:lotus_dashboard_card_filter_mappings, [:card_id, :filter_id, :variable_name],
        name: "lotus_dashboard_card_filter_mappings_card_filter_variable_index"
      )
    )

    drop_if_exists(index(:lotus_dashboard_card_filter_mappings, [:filter_id]))
    drop_if_exists(index(:lotus_dashboard_card_filter_mappings, [:card_id]))
    drop_if_exists(table(:lotus_dashboard_card_filter_mappings))

    drop_if_exists(
      index(:lotus_dashboard_filters, [:dashboard_id, :name],
        name: "lotus_dashboard_filters_dashboard_id_name_index"
      )
    )

    drop_if_exists(index(:lotus_dashboard_filters, [:depends_on_filter_id]))
    drop_if_exists(index(:lotus_dashboard_filters, [:source_query_id]))
    drop_if_exists(index(:lotus_dashboard_filters, [:dashboard_id, :position]))
    drop_if_exists(table(:lotus_dashboard_filters))

    drop_if_exists(index(:lotus_dashboard_cards, [:dashboard_id, :position]))
    drop_if_exists(table(:lotus_dashboard_cards))

    drop_if_exists(
      index(:lotus_dashboards, [:public_token], name: "lotus_dashboards_public_token_index")
    )

    drop_tenant_indexes(:lotus_dashboards)
    drop_if_exists(table(:lotus_dashboards))

    drop_if_exists(
      index(:lotus_query_visualizations, [:query_id, :name],
        name: "lotus_query_visualizations_query_id_name_index"
      )
    )

    drop_if_exists(index(:lotus_query_visualizations, [:query_id, :position]))
    drop_if_exists(table(:lotus_query_visualizations))

    drop_tenant_indexes(:lotus_queries)
    drop_if_exists(table(:lotus_queries))

    :ok
  end

  @impl Lotus.Migration
  def migrated_version(_opts), do: 0

  # A name is unique within a tenant: one index for the rows without a tenant,
  # one for the rows of each tenant.
  defp create_tenant_indexes(table) do
    create_if_not_exists(
      unique_index(table, [:name], name: "#{table}_name_index", where: "tenant_id IS NULL")
    )

    create_if_not_exists(
      unique_index(table, [:tenant_id, :name], name: "#{table}_tenant_id_name_index")
    )

    create_if_not_exists(index(table, [:owner_id]))
  end

  defp drop_tenant_indexes(table) do
    drop_if_exists(index(table, [:owner_id]))
    drop_if_exists(index(table, [:tenant_id, :name], name: "#{table}_tenant_id_name_index"))
    drop_if_exists(index(table, [:name], name: "#{table}_name_index"))
  end

  # SQLite migrations are single-file and unversioned, so there is no V4-style
  # compensating migration (as on Postgres) to rename `data_repo` →
  # `data_source` on an upgrading install. Without this guard, `up/1` is a
  # no-op on an existing table — `mix ecto.migrate` reports success while
  # leaving the legacy column in place, and every read then crashes in
  # production. Detect the legacy column and fail at migrate time instead.
  defp ensure_data_source_column! do
    %{rows: rows} =
      repo().query!("SELECT 1 FROM pragma_table_info('lotus_queries') WHERE name = 'data_repo'")

    if rows != [] do
      raise """
      Lotus v1.0 renamed the lotus_queries `data_repo` column to `data_source`.
      SQLite migrations are unversioned and cannot perform this rename for you.
      Run it once before re-running migrations:

          ALTER TABLE lotus_queries RENAME COLUMN data_repo TO data_source;

      See guides/upgrading-to-v1.md section 3.
      """
    end
  end
end
