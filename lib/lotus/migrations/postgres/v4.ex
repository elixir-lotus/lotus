defmodule Lotus.Migrations.Postgres.V4 do
  @moduledoc """
  Rename legacy `data_repo` column to `data_source` on upgrading installs.

  Fresh installs never created the `data_repo` column — V1 (updated for v1.0)
  now creates `data_source` directly. This migration is a no-op for those
  installs. Upgrading installs that ran V1 before the rename still have the
  `data_repo` column, and the `DO $$` block below renames it in place.
  """

  use Ecto.Migration

  @table_name :lotus_queries

  def up(opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "public")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}'
          AND table_name = '#{@table_name}'
          AND column_name = 'data_repo'
      ) THEN
        ALTER TABLE #{prefix}.#{@table_name} RENAME COLUMN data_repo TO data_source;
      END IF;
    END $$;
    """)
  end

  def down(opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "public")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}'
          AND table_name = '#{@table_name}'
          AND column_name = 'data_source'
      ) THEN
        ALTER TABLE #{prefix}.#{@table_name} RENAME COLUMN data_source TO data_repo;
      END IF;
    END $$;
    """)
  end
end
