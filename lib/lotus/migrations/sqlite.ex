defmodule Lotus.Migrations.SQLite do
  @moduledoc false

  @behaviour Lotus.Migration

  use Ecto.Migration

  @impl Lotus.Migration
  def up(_opts \\ []) do
    create_if_not_exists table(:lotus_queries, primary_key: false) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:statement, :text, null: false)
      add(:variables, :map, null: false, default: "[]")
      add(:data_source, :string)
      add(:search_path, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(unique_index(:lotus_queries, [:name], name: "lotus_queries_name_index"))

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
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(:lotus_dashboards, [:name], name: "lotus_dashboards_name_index")
    )

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
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(index(:lotus_dashboard_filters, [:dashboard_id, :position]))

    create_if_not_exists(
      unique_index(:lotus_dashboard_filters, [:dashboard_id, :name],
        name: "lotus_dashboard_filters_dashboard_id_name_index"
      )
    )

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

    :ok
  end

  @impl Lotus.Migration
  def down(_opts \\ []) do
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

    drop_if_exists(index(:lotus_dashboard_filters, [:dashboard_id, :position]))
    drop_if_exists(table(:lotus_dashboard_filters))

    drop_if_exists(index(:lotus_dashboard_cards, [:dashboard_id, :position]))
    drop_if_exists(table(:lotus_dashboard_cards))

    drop_if_exists(
      index(:lotus_dashboards, [:public_token], name: "lotus_dashboards_public_token_index")
    )

    drop_if_exists(index(:lotus_dashboards, [:name], name: "lotus_dashboards_name_index"))
    drop_if_exists(table(:lotus_dashboards))

    drop_if_exists(
      index(:lotus_query_visualizations, [:query_id, :name],
        name: "lotus_query_visualizations_query_id_name_index"
      )
    )

    drop_if_exists(index(:lotus_query_visualizations, [:query_id, :position]))
    drop_if_exists(table(:lotus_query_visualizations))

    drop_if_exists(index(:lotus_queries, [:name], name: "lotus_queries_name_index"))
    drop_if_exists(table(:lotus_queries))

    :ok
  end

  @impl Lotus.Migration
  def migrated_version(_opts), do: 0
end
