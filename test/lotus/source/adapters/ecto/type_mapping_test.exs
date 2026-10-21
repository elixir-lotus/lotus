defmodule Lotus.Source.Adapters.Ecto.TypeMappingTest do
  use Lotus.Case, async: true

  alias Lotus.Source.Adapters.Ecto.Dialects

  describe "db_type_to_lotus_type/1 for PostgreSQL" do
    test "maps uuid to :uuid" do
      assert Dialects.Postgres.db_type_to_lotus_type("uuid") == :uuid
      assert Dialects.Postgres.db_type_to_lotus_type("UUID") == :uuid
    end

    test "maps integer types to :integer" do
      assert Dialects.Postgres.db_type_to_lotus_type("integer") == :integer
      assert Dialects.Postgres.db_type_to_lotus_type("bigint") == :integer
      assert Dialects.Postgres.db_type_to_lotus_type("smallint") == :integer
      assert Dialects.Postgres.db_type_to_lotus_type("serial") == :integer
      assert Dialects.Postgres.db_type_to_lotus_type("bigserial") == :integer
    end

    test "maps numeric/decimal types to :decimal" do
      assert Dialects.Postgres.db_type_to_lotus_type("numeric") == :decimal
      assert Dialects.Postgres.db_type_to_lotus_type("numeric(10,2)") == :decimal
      assert Dialects.Postgres.db_type_to_lotus_type("decimal") == :decimal
      assert Dialects.Postgres.db_type_to_lotus_type("decimal(18,4)") == :decimal
    end

    test "maps float types to :float" do
      assert Dialects.Postgres.db_type_to_lotus_type("real") == :float
      assert Dialects.Postgres.db_type_to_lotus_type("double precision") == :float
    end

    test "maps boolean to :boolean" do
      assert Dialects.Postgres.db_type_to_lotus_type("boolean") == :boolean
      assert Dialects.Postgres.db_type_to_lotus_type("BOOLEAN") == :boolean
    end

    test "maps date to :date" do
      assert Dialects.Postgres.db_type_to_lotus_type("date") == :date
    end

    test "maps timestamp types to :datetime" do
      assert Dialects.Postgres.db_type_to_lotus_type("timestamp") == :datetime

      assert Dialects.Postgres.db_type_to_lotus_type("timestamp without time zone") ==
               :datetime

      assert Dialects.Postgres.db_type_to_lotus_type("timestamp with time zone") == :datetime
      assert Dialects.Postgres.db_type_to_lotus_type("timestamptz") == :datetime
    end

    test "maps time types to :time" do
      assert Dialects.Postgres.db_type_to_lotus_type("time") == :time
      assert Dialects.Postgres.db_type_to_lotus_type("time without time zone") == :time
    end

    test "maps json types to :json" do
      assert Dialects.Postgres.db_type_to_lotus_type("json") == :json
      assert Dialects.Postgres.db_type_to_lotus_type("jsonb") == :json
    end

    test "maps bytea to :binary" do
      assert Dialects.Postgres.db_type_to_lotus_type("bytea") == :binary
    end

    test "maps USER-DEFINED to :enum" do
      assert Dialects.Postgres.db_type_to_lotus_type("USER-DEFINED") == :enum
      assert Dialects.Postgres.db_type_to_lotus_type("user-defined") == :enum
    end

    test "maps array types recursively" do
      assert Dialects.Postgres.db_type_to_lotus_type("integer[]") == {:array, :integer}
      assert Dialects.Postgres.db_type_to_lotus_type("uuid[]") == {:array, :uuid}
      assert Dialects.Postgres.db_type_to_lotus_type("text[]") == {:array, :text}
      assert Dialects.Postgres.db_type_to_lotus_type("boolean[]") == {:array, :boolean}
    end

    test "defaults text/varchar to :text" do
      assert Dialects.Postgres.db_type_to_lotus_type("text") == :text
      assert Dialects.Postgres.db_type_to_lotus_type("varchar") == :text
      assert Dialects.Postgres.db_type_to_lotus_type("character varying") == :text
      assert Dialects.Postgres.db_type_to_lotus_type("char") == :text
    end

    test "defaults unknown types to :text" do
      assert Dialects.Postgres.db_type_to_lotus_type("custom_type") == :text
      assert Dialects.Postgres.db_type_to_lotus_type("unknown") == :text
    end
  end

  describe "db_type_to_lotus_type/1 for MySQL" do
    test "maps char(36) and char(32) to :text, since they hold text" do
      assert Dialects.MySQL.db_type_to_lotus_type("char(36)") == :text
      assert Dialects.MySQL.db_type_to_lotus_type("char(32)") == :text
    end

    test "maps binary(16) to :uuid" do
      assert Dialects.MySQL.db_type_to_lotus_type("binary(16)") == :uuid
    end

    test "maps integer types to :integer" do
      assert Dialects.MySQL.db_type_to_lotus_type("int") == :integer
      assert Dialects.MySQL.db_type_to_lotus_type("int(11)") == :integer
      assert Dialects.MySQL.db_type_to_lotus_type("bigint") == :integer
      assert Dialects.MySQL.db_type_to_lotus_type("bigint(20)") == :integer
      assert Dialects.MySQL.db_type_to_lotus_type("smallint") == :integer
    end

    test "maps tinyint(1) to :boolean" do
      assert Dialects.MySQL.db_type_to_lotus_type("tinyint(1)") == :boolean
    end

    test "maps other tinyint to :integer" do
      assert Dialects.MySQL.db_type_to_lotus_type("tinyint") == :integer
      assert Dialects.MySQL.db_type_to_lotus_type("tinyint(4)") == :integer
    end

    test "maps decimal types to :decimal" do
      assert Dialects.MySQL.db_type_to_lotus_type("decimal") == :decimal
      assert Dialects.MySQL.db_type_to_lotus_type("decimal(10,2)") == :decimal
      assert Dialects.MySQL.db_type_to_lotus_type("numeric") == :decimal
    end

    test "maps float types to :float" do
      assert Dialects.MySQL.db_type_to_lotus_type("float") == :float
      assert Dialects.MySQL.db_type_to_lotus_type("double") == :float
    end

    test "maps date to :date" do
      assert Dialects.MySQL.db_type_to_lotus_type("date") == :date
    end

    test "maps datetime types to :datetime" do
      assert Dialects.MySQL.db_type_to_lotus_type("datetime") == :datetime
      assert Dialects.MySQL.db_type_to_lotus_type("timestamp") == :datetime
    end

    test "maps json to :json" do
      assert Dialects.MySQL.db_type_to_lotus_type("json") == :json
    end

    test "defaults text types to :text" do
      assert Dialects.MySQL.db_type_to_lotus_type("varchar") == :text
      assert Dialects.MySQL.db_type_to_lotus_type("varchar(255)") == :text
      assert Dialects.MySQL.db_type_to_lotus_type("text") == :text
      assert Dialects.MySQL.db_type_to_lotus_type("mediumtext") == :text
    end

    test "defaults unknown types to :text" do
      assert Dialects.MySQL.db_type_to_lotus_type("unknown") == :text
    end
  end

  describe "db_type_to_lotus_type/1 for SQLite" do
    test "maps INTEGER to :integer" do
      assert Dialects.SQLite3.db_type_to_lotus_type("INTEGER") == :integer
      assert Dialects.SQLite3.db_type_to_lotus_type("integer") == :integer
    end

    test "maps REAL to :float" do
      assert Dialects.SQLite3.db_type_to_lotus_type("REAL") == :float
      assert Dialects.SQLite3.db_type_to_lotus_type("real") == :float
    end

    test "maps NUMERIC to :decimal" do
      assert Dialects.SQLite3.db_type_to_lotus_type("NUMERIC") == :decimal
    end

    test "maps DATE to :date" do
      assert Dialects.SQLite3.db_type_to_lotus_type("DATE") == :date
    end

    test "maps DATETIME to :datetime" do
      assert Dialects.SQLite3.db_type_to_lotus_type("DATETIME") == :datetime
    end

    test "maps BLOB to :binary" do
      assert Dialects.SQLite3.db_type_to_lotus_type("BLOB") == :binary
    end

    test "defaults TEXT to :text" do
      assert Dialects.SQLite3.db_type_to_lotus_type("TEXT") == :text
    end

    test "defaults unknown types to :text" do
      assert Dialects.SQLite3.db_type_to_lotus_type("UUID") == :text
      assert Dialects.SQLite3.db_type_to_lotus_type("VARCHAR") == :text
    end

    test "prefix-matches parameterized and family variants" do
      # Parameterized declarations
      assert Dialects.SQLite3.db_type_to_lotus_type("DECIMAL(10,2)") == :decimal
      assert Dialects.SQLite3.db_type_to_lotus_type("NUMERIC(5)") == :decimal
      assert Dialects.SQLite3.db_type_to_lotus_type("VARCHAR(255)") == :text

      # Integer family
      assert Dialects.SQLite3.db_type_to_lotus_type("BIGINT") == :integer
      assert Dialects.SQLite3.db_type_to_lotus_type("SMALLINT") == :integer
      assert Dialects.SQLite3.db_type_to_lotus_type("TINYINT") == :integer
      assert Dialects.SQLite3.db_type_to_lotus_type("MEDIUMINT") == :integer
      assert Dialects.SQLite3.db_type_to_lotus_type("INT8") == :integer

      # Float family
      assert Dialects.SQLite3.db_type_to_lotus_type("FLOAT") == :float
      assert Dialects.SQLite3.db_type_to_lotus_type("DOUBLE") == :float

      # Other scalar families that previously fell through to :text
      assert Dialects.SQLite3.db_type_to_lotus_type("BOOLEAN") == :boolean
      assert Dialects.SQLite3.db_type_to_lotus_type("TIMESTAMP") == :datetime
      assert Dialects.SQLite3.db_type_to_lotus_type("TIME") == :time
    end
  end

  describe "type consistency across databases" do
    @common_concepts [
      {:integer, "integer", "int", "INTEGER"},
      {:float, "real", "float", "REAL"},
      {:decimal, "numeric", "decimal", "NUMERIC"},
      {:date, "date", "date", "DATE"},
      {:datetime, "timestamp", "datetime", "DATETIME"},
      {:json, "json", "json", nil}
    ]

    for {lotus_type, pg_type, mysql_type, sqlite_type} <- @common_concepts, sqlite_type != nil do
      test "#{lotus_type} maps consistently across databases" do
        pg_result = Dialects.Postgres.db_type_to_lotus_type(unquote(pg_type))
        mysql_result = Dialects.MySQL.db_type_to_lotus_type(unquote(mysql_type))
        sqlite_result = Dialects.SQLite3.db_type_to_lotus_type(unquote(sqlite_type))

        assert pg_result == unquote(lotus_type)
        assert mysql_result == unquote(lotus_type)
        assert sqlite_result == unquote(lotus_type)
      end
    end
  end
end
