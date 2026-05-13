defmodule Lotus.Migrations.MySQL do
  @moduledoc false

  @behaviour Lotus.Migration

  use Ecto.Migration

  @impl Lotus.Migration
  def up(_opts \\ []) do
    create_if_not_exists table(:lotus_queries, primary_key: false) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, size: 255, null: false)
      add(:description, :text)
      add(:statement, :text, null: false)
      add(:variables, :json, null: false, default: fragment("('[]')"))
      add(:data_source, :string, size: 255)
      add(:search_path, :string, size: 255)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
    end

    create(unique_index(:lotus_queries, [:name], name: "lotus_queries_name_index"))

    create_if_not_exists table(:lotus_query_visualizations, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:query_id, references(:lotus_queries, type: :serial, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, size: 255, null: false)
      add(:position, :integer, null: false)
      add(:config, :json, null: false, default: fragment("('{}')"))
      add(:version, :integer, null: false, default: 1)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
    end

    create(index(:lotus_query_visualizations, [:query_id, :position]))

    create(
      unique_index(:lotus_query_visualizations, [:query_id, :name],
        name: "lotus_query_visualizations_query_id_name_index"
      )
    )

    create_if_not_exists table(:lotus_dashboards, primary_key: false) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, size: 255, null: false)
      add(:description, :text)
      add(:settings, :json, null: false, default: fragment("('{}')"))
      add(:public_token, :string, size: 255)
      add(:auto_refresh_seconds, :integer)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
    end

    create(unique_index(:lotus_dashboards, [:name], name: "lotus_dashboards_name_index"))

    create(
      unique_index(:lotus_dashboards, [:public_token],
        name: "lotus_dashboards_public_token_index"
      )
    )

    create_if_not_exists table(:lotus_dashboard_cards, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:dashboard_id, references(:lotus_dashboards, type: :serial, on_delete: :delete_all),
        null: false
      )

      add(:query_id, references(:lotus_queries, type: :serial, on_delete: :nilify_all))

      add(:card_type, :string, size: 50, null: false)
      add(:title, :string, size: 255)
      add(:visualization_config, :json)
      add(:content, :json, null: false, default: fragment("('{}')"))
      add(:position, :integer, null: false)
      # credo:disable-for-next-line Credo.Check.Readability.StringSigils
      add(:layout, :json, null: false, default: fragment("('{\"x\":0,\"y\":0,\"w\":6,\"h\":4}')"))
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
    end

    create(index(:lotus_dashboard_cards, [:dashboard_id, :position]))

    create_if_not_exists table(:lotus_dashboard_filters, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:dashboard_id, references(:lotus_dashboards, type: :serial, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, size: 255, null: false)
      add(:label, :string, size: 255, null: false)
      add(:filter_type, :string, size: 50, null: false)
      add(:widget, :string, size: 50, null: false)
      add(:default_value, :string, size: 255)
      add(:config, :json, null: false, default: fragment("('{}')"))
      add(:position, :integer, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
    end

    create(index(:lotus_dashboard_filters, [:dashboard_id, :position]))

    create(
      unique_index(:lotus_dashboard_filters, [:dashboard_id, :name],
        name: "lotus_dashboard_filters_dashboard_id_name_index"
      )
    )

    create_if_not_exists table(:lotus_dashboard_card_filter_mappings, primary_key: false) do
      add(:id, :serial, primary_key: true)

      add(:card_id, references(:lotus_dashboard_cards, type: :serial, on_delete: :delete_all),
        null: false
      )

      add(:filter_id, references(:lotus_dashboard_filters, type: :serial, on_delete: :delete_all),
        null: false
      )

      add(:variable_name, :string, size: 255, null: false)
      add(:transform, :json)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("(UTC_TIMESTAMP(6))"))
    end

    create(index(:lotus_dashboard_card_filter_mappings, [:card_id]))
    create(index(:lotus_dashboard_card_filter_mappings, [:filter_id]))

    create(
      unique_index(:lotus_dashboard_card_filter_mappings, [:card_id, :filter_id, :variable_name],
        name: "lotus_dashboard_card_filter_mappings_card_filter_variable_index"
      )
    )

    :ok
  end

  @impl Lotus.Migration
  def down(_opts \\ []) do
    drop(table(:lotus_dashboard_card_filter_mappings))
    drop(table(:lotus_dashboard_filters))
    drop(table(:lotus_dashboard_cards))

    drop(index(:lotus_dashboards, [:public_token], name: "lotus_dashboards_public_token_index"))
    drop(index(:lotus_dashboards, [:name], name: "lotus_dashboards_name_index"))
    drop(table(:lotus_dashboards))

    drop(table(:lotus_query_visualizations))
    drop(index(:lotus_queries, [:name], name: "lotus_queries_name_index"))
    drop(table(:lotus_queries))

    :ok
  end

  @impl Lotus.Migration
  def migrated_version(_opts), do: 0
end
