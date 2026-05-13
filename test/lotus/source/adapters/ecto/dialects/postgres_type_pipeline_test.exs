defmodule Lotus.Source.Adapters.Ecto.Dialects.PostgresTypePipelineTest do
  @moduledoc """
  End-to-end tests for the Postgres type-detection pipeline:
  `describe_table/3` (extractor) → `db_type_to_lotus_type/1` (mapper) →
  `TypeCaster.cast_value/3` (caster).

  Unit tests on the mapper alone pass hand-rolled strings and cannot catch
  drift between what `information_schema.columns` emits and what the mapper
  pattern-matches on. These tests run the whole chain against the real
  Postgres test schema.
  """

  use Lotus.Case

  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Source.Adapters.Ecto.Dialects.Postgres
  alias Lotus.Storage.TypeCaster

  @adapter EctoAdapter.wrap("postgres", Lotus.Test.Repo)

  defp raw_type(table, column) do
    {:ok, columns} = Adapter.describe_table(@adapter, "public", table)
    found = Enum.find(columns, &(&1.name == column))
    refute is_nil(found), "expected column #{inspect(column)} in #{table}"
    found.type
  end

  defp lotus_type(table, column),
    do: Postgres.db_type_to_lotus_type(raw_type(table, column))

  # Runs extractor → mapper → caster in one call.
  defp cast_via_pipeline(table, column, value) do
    column_info = %{table: table, column: column, adapter: @adapter}
    TypeCaster.cast_value(value, raw_type(table, column), column_info)
  end

  describe "extractor emits types that round-trip through the mapper" do
    test "integer PRIMARY KEY → :integer" do
      assert lotus_type("test_users", "id") == :integer
    end

    test "varchar / string → :text" do
      assert lotus_type("test_users", "email") == :text
    end

    test "boolean → :boolean" do
      assert lotus_type("test_users", "active") == :boolean
    end

    test "jsonb → :json" do
      assert lotus_type("test_users", "metadata") == :json
    end

    test "utc_datetime → :datetime" do
      assert lotus_type("test_users", "inserted_at") == :datetime
    end

    test "uuid → :uuid" do
      assert lotus_type("test_uuid_records", "id") == :uuid
    end
  end

  describe "extractor → mapper → caster" do
    test "boolean casts 'true'/'false' end-to-end" do
      assert {:ok, true} = cast_via_pipeline("test_users", "active", "true")
      assert {:ok, false} = cast_via_pipeline("test_users", "active", "false")
    end

    test "integer casts numeric strings" do
      assert {:ok, 42} = cast_via_pipeline("test_users", "id", "42")
    end

    test "uuid casts text UUIDs to Ecto binary form" do
      assert {:ok, binary} =
               cast_via_pipeline(
                 "test_uuid_records",
                 "id",
                 "550e8400-e29b-41d4-a716-446655440000"
               )

      assert byte_size(binary) == 16
    end

    test "varchar / string passes through" do
      assert {:ok, "hello@example.com"} =
               cast_via_pipeline("test_users", "email", "hello@example.com")
    end
  end
end
