defmodule Lotus.Test.MysqlRepo.Migrations.CreateUuidTables do
  use Ecto.Migration

  # The three ways a MySQL table stores a UUID: as text with dashes, as hex
  # without them, and as 16 raw bytes.
  def change do
    create table(:test_uuid_keys, primary_key: false) do
      add(:text_id, :"char(36)", null: false)
      add(:hex_id, :"char(32)", null: false)
      add(:binary_id, :"binary(16)", null: false)
      add(:label, :string, null: false)
    end
  end
end
