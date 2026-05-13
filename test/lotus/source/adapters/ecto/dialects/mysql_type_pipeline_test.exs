defmodule Lotus.Source.Adapters.Ecto.Dialects.MySQLTypePipelineTest do
  @moduledoc """
  End-to-end tests for the MySQL type-detection pipeline:
  `describe_table/3` (extractor) → `db_type_to_lotus_type/1` (mapper) →
  `TypeCaster.cast_value/3` (caster).

  Unit tests on the mapper in isolation pass hand-rolled strings and cannot
  catch bugs where the extractor emits a different string than the mapper
  pattern-matches on (e.g. `"tinyint"` vs `"tinyint(1)"`). These tests run
  the whole chain against the real MySQL test schema.
  """

  use Lotus.Case
  @moduletag :mysql

  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Source.Adapters.Ecto.Dialects.MySQL
  alias Lotus.Storage.TypeCaster

  @mysql_adapter EctoAdapter.wrap("mysql", Lotus.Test.MysqlRepo)
  @mysql_database Lotus.Test.MysqlRepo.config()[:database]

  # Returns the raw type string the extractor emits for a column.
  defp column_type(table, column) do
    {:ok, columns} = Adapter.describe_table(@mysql_adapter, @mysql_database, table)
    found = Enum.find(columns, &(&1.name == column))
    refute is_nil(found), "expected column #{inspect(column)} in #{table}"
    found.type
  end

  # Runs the full extractor → mapper → caster pipeline. TypeCaster.cast_value/3
  # with a binary db_type calls Adapter.db_type_to_lotus_type internally, so
  # one call exercises the entire chain.
  defp cast_via_pipeline(table, column, raw_value) do
    raw_type = column_type(table, column)
    column_info = %{table: table, column: column, adapter: @mysql_adapter}
    {raw_type, TypeCaster.cast_value(raw_value, raw_type, column_info)}
  end

  describe "extractor emits parameterized types" do
    test "TINYINT(1) (not bare 'tinyint') so the boolean mapping is reachable" do
      # Regression: the extractor used c.data_type (base name) which made
      # "tinyint(1) -> :boolean" in the mapper unreachable — booleans
      # silently typed as :integer.
      assert column_type("test_users", "active") == "tinyint(1)"
    end

    test "VARCHAR(N) keeps its length in the emitted string" do
      assert String.starts_with?(column_type("test_users", "email"), "varchar(")
    end
  end

  describe "mapper produces correct Lotus type for extracted strings" do
    test "TINYINT(1) → :boolean" do
      assert MySQL.db_type_to_lotus_type(column_type("test_users", "active")) == :boolean
    end

    test "INT → :integer" do
      assert MySQL.db_type_to_lotus_type(column_type("test_users", "id")) == :integer
    end

    test "VARCHAR(N) → :text" do
      assert MySQL.db_type_to_lotus_type(column_type("test_users", "email")) == :text
    end
  end

  describe "caster uses the extracted type to cast values end-to-end" do
    test "TINYINT(1) casts '1'/'0' as booleans" do
      assert {"tinyint(1)", {:ok, true}} = cast_via_pipeline("test_users", "active", "1")
      assert {"tinyint(1)", {:ok, false}} = cast_via_pipeline("test_users", "active", "0")
    end

    test "INT casts numeric strings as integers" do
      assert {_raw, {:ok, 42}} = cast_via_pipeline("test_users", "id", "42")
    end

    test "VARCHAR passes through text unchanged" do
      assert {_raw, {:ok, "hello"}} = cast_via_pipeline("test_users", "email", "hello")
    end
  end
end
