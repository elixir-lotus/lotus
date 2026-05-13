defmodule Lotus.Migrations.Postgres.V1 do
  @moduledoc """
  Initial table structure for Lotus queries on PostgreSQL.
  """

  use Ecto.Migration

  @table_name :lotus_queries

  def up(opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "public")
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    create_if_not_exists table(
                           @table_name,
                           [primary_key: false] ++ table_opts
                         ) do
      add(:id, :serial, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:statement, :text, null: false)
      add(:variables, :map, null: false, default: "[]")
      add(:data_source, :string)
      add(:search_path, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(@table_name, [:name], name: "#{@table_name}_name_index", prefix: prefix)
    )

    execute("COMMENT ON TABLE #{prefix}.#{@table_name} IS '1'")
  end

  def down(opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "public")
    table_opts = Map.take(opts, [:prefix]) |> Map.to_list()

    drop_if_exists(index(@table_name, [:name], name: "#{@table_name}_name_index", prefix: prefix))
    drop_if_exists(table(@table_name, table_opts))
  end
end
