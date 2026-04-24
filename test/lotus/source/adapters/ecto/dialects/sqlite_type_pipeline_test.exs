defmodule Lotus.Source.Adapters.Ecto.Dialects.SQLite3TypePipelineTest do
  @moduledoc """
  End-to-end tests for the SQLite type-detection pipeline:
  `describe_table/3` (extractor) → `db_type_to_lotus_type/1` (mapper).

  Unit tests on the mapper alone pass hand-rolled strings and miss the case
  where a user hand-writes a CREATE TABLE with types like `BOOLEAN`,
  `TIMESTAMP`, `DECIMAL(10,2)`, or `VARCHAR(255)`. SQLite accepts these
  verbatim (it has dynamic typing); the extractor returns them verbatim via
  PRAGMA table_info; and before the fix the mapper fell through to `:text`
  for all of them.
  """

  use Lotus.Case, sqlite: true
  @moduletag :sqlite

  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Source.Adapters.Ecto.Dialects.SQLite3
  alias Lotus.Storage.TypeCaster
  alias Lotus.Test.SqliteRepo

  @adapter EctoAdapter.wrap("sqlite", SqliteRepo)

  setup do
    table = "lotus_types_probe_#{System.unique_integer([:positive])}"

    SqliteRepo.query!("""
    CREATE TABLE #{table} (
      id INTEGER PRIMARY KEY,
      bigint_col BIGINT,
      float_col FLOAT,
      double_col DOUBLE,
      decimal_col DECIMAL(10,2),
      numeric_col NUMERIC(5),
      varchar_col VARCHAR(255),
      boolean_col BOOLEAN,
      timestamp_col TIMESTAMP
    )
    """)

    on_exit(fn -> SqliteRepo.query!("DROP TABLE IF EXISTS #{table}") end)

    {:ok, table: table}
  end

  defp raw_type(table, column) do
    {:ok, columns} = Adapter.describe_table(@adapter, nil, table)
    found = Enum.find(columns, &(&1.name == column))
    refute is_nil(found), "expected #{inspect(column)} in #{table}"
    found.type
  end

  defp lotus_type(table, column), do: SQLite3.db_type_to_lotus_type(raw_type(table, column))

  # Runs extractor → mapper → caster in one call: TypeCaster.cast_value/3 with
  # a binary db_type calls Adapter.db_type_to_lotus_type internally.
  defp cast_via_pipeline(table, column, value) do
    column_info = %{table: table, column: column, adapter: @adapter}
    TypeCaster.cast_value(value, raw_type(table, column), column_info)
  end

  describe "extractor → mapper" do
    test "parameterized DECIMAL(10,2) → :decimal", %{table: t} do
      assert lotus_type(t, "decimal_col") == :decimal
    end

    test "parameterized NUMERIC(5) → :decimal", %{table: t} do
      assert lotus_type(t, "numeric_col") == :decimal
    end

    test "parameterized VARCHAR(255) → :text", %{table: t} do
      assert lotus_type(t, "varchar_col") == :text
    end

    test "BIGINT → :integer", %{table: t} do
      assert lotus_type(t, "bigint_col") == :integer
    end

    test "FLOAT → :float", %{table: t} do
      assert lotus_type(t, "float_col") == :float
    end

    test "DOUBLE → :float", %{table: t} do
      assert lotus_type(t, "double_col") == :float
    end

    test "BOOLEAN → :boolean", %{table: t} do
      assert lotus_type(t, "boolean_col") == :boolean
    end

    test "TIMESTAMP → :datetime", %{table: t} do
      assert lotus_type(t, "timestamp_col") == :datetime
    end
  end

  describe "extractor → mapper → caster" do
    test "BOOLEAN casts '1'/'0' as booleans end-to-end", %{table: t} do
      assert {:ok, true} = cast_via_pipeline(t, "boolean_col", "1")
      assert {:ok, false} = cast_via_pipeline(t, "boolean_col", "0")
    end

    test "BIGINT casts numeric strings as integers", %{table: t} do
      assert {:ok, 9_999_999_999} = cast_via_pipeline(t, "bigint_col", "9999999999")
    end

    test "DECIMAL(10,2) casts strings as Decimals", %{table: t} do
      assert {:ok, %Decimal{} = d} = cast_via_pipeline(t, "decimal_col", "12.34")
      assert Decimal.equal?(d, Decimal.new("12.34"))
    end

    test "VARCHAR(255) passes text through unchanged", %{table: t} do
      assert {:ok, "hello"} = cast_via_pipeline(t, "varchar_col", "hello")
    end
  end
end
