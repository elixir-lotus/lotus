defmodule Lotus.Source.Adapters.Ecto.Dialects.EditorConfigTest do
  use ExUnit.Case, async: true

  alias Lotus.Source.Adapters.Ecto.Dialects.Default
  alias Lotus.Source.Adapters.Ecto.Dialects.MySQL
  alias Lotus.Source.Adapters.Ecto.Dialects.Postgres
  alias Lotus.Source.Adapters.Ecto.Dialects.SQLite3

  @required_keys [:language, :keywords, :types, :functions, :context_boundaries]

  describe "Default.editor_config/0" do
    test "returns base SQL config with all required keys" do
      config = Default.editor_config()
      for key <- @required_keys, do: assert(Map.has_key?(config, key), "missing key: #{key}")
      assert config.language == "sql"
    end

    test "includes standard SQL keywords" do
      config = Default.editor_config()
      keywords = Enum.map(config.keywords, &String.upcase/1)
      assert "SELECT" in keywords
      assert "FROM" in keywords
      assert "WHERE" in keywords
      assert "JOIN" in keywords
      assert "GROUP" in keywords
      assert "ORDER" in keywords
      assert "HAVING" in keywords
      assert "LIMIT" in keywords
      assert "INSERT" in keywords
      assert "UPDATE" in keywords
      assert "DELETE" in keywords
    end

    test "includes standard SQL functions" do
      config = Default.editor_config()
      names = Enum.map(config.functions, & &1.name)
      assert "COUNT" in names
      assert "SUM" in names
      assert "AVG" in names
      assert "MAX" in names
      assert "MIN" in names
    end

    test "functions have required fields" do
      config = Default.editor_config()

      for func <- config.functions do
        assert is_binary(func.name), "function missing name"
        assert is_binary(func.detail), "function #{func.name} missing detail"
        assert is_binary(func.args), "function #{func.name} missing args"
      end
    end

    test "includes standard SQL types" do
      config = Default.editor_config()
      types = Enum.map(config.types, &String.upcase/1)
      assert "INTEGER" in types
      assert "VARCHAR" in types
      assert "TEXT" in types
      assert "BOOLEAN" in types
    end
  end

  describe "Postgres.editor_config/0" do
    test "returns sql language with all required keys" do
      config = Postgres.editor_config()
      for key <- @required_keys, do: assert(Map.has_key?(config, key), "missing key: #{key}")
      assert config.language == "sql"
    end

    test "includes Postgres-specific keywords" do
      config = Postgres.editor_config()
      keywords = Enum.map(config.keywords, &String.upcase/1)
      assert "RETURNING" in keywords
      assert "ILIKE" in keywords
      assert "LATERAL" in keywords
    end

    test "includes Postgres-specific types" do
      config = Postgres.editor_config()
      types = Enum.map(config.types, &String.downcase/1)
      assert "jsonb" in types
      assert "uuid" in types
      assert "serial" in types
      assert "timestamptz" in types
      assert "inet" in types
    end

    test "includes Postgres-specific functions" do
      config = Postgres.editor_config()
      names = Enum.map(config.functions, & &1.name)
      assert "array_agg" in names
      assert "string_agg" in names
      assert "json_build_object" in names
      assert "generate_series" in names
      assert "date_trunc" in names
    end

    test "functions have required fields" do
      config = Postgres.editor_config()

      for func <- config.functions do
        assert is_binary(func.name), "function missing name"
        assert is_binary(func.detail), "function #{func.name} missing detail"
        assert is_binary(func.args), "function #{func.name} missing args"
      end
    end
  end

  describe "MySQL.editor_config/0" do
    test "returns sql language with all required keys" do
      config = MySQL.editor_config()
      for key <- @required_keys, do: assert(Map.has_key?(config, key), "missing key: #{key}")
      assert config.language == "sql"
    end

    test "includes MySQL-specific keywords" do
      config = MySQL.editor_config()
      keywords = Enum.map(config.keywords, &String.upcase/1)
      assert "AUTO_INCREMENT" in keywords
      assert "ENGINE" in keywords
      assert "UNSIGNED" in keywords
    end

    test "includes MySQL-specific types" do
      config = MySQL.editor_config()
      types = Enum.map(config.types, &String.downcase/1)
      assert "tinyint" in types
      assert "mediumint" in types
      assert "longtext" in types
      assert "enum" in types
    end

    test "includes MySQL-specific functions" do
      config = MySQL.editor_config()
      names = Enum.map(config.functions, & &1.name)
      assert "GROUP_CONCAT" in names
      assert "IFNULL" in names
      assert "DATE_FORMAT" in names
    end

    test "functions have required fields" do
      config = MySQL.editor_config()

      for func <- config.functions do
        assert is_binary(func.name), "function missing name"
        assert is_binary(func.detail), "function #{func.name} missing detail"
        assert is_binary(func.args), "function #{func.name} missing args"
      end
    end
  end

  describe "SQLite3.editor_config/0" do
    test "returns sql language with all required keys" do
      config = SQLite3.editor_config()
      for key <- @required_keys, do: assert(Map.has_key?(config, key), "missing key: #{key}")
      assert config.language == "sql"
    end

    test "includes SQLite-specific keywords" do
      config = SQLite3.editor_config()
      keywords = Enum.map(config.keywords, &String.upcase/1)
      assert "AUTOINCREMENT" in keywords
      assert "GLOB" in keywords
      assert "PRAGMA" in keywords
      assert "VACUUM" in keywords
    end

    test "includes SQLite type affinity types" do
      config = SQLite3.editor_config()
      types = Enum.map(config.types, &String.upcase/1)
      assert "INTEGER" in types
      assert "REAL" in types
      assert "TEXT" in types
      assert "BLOB" in types
    end

    test "includes SQLite-specific functions" do
      config = SQLite3.editor_config()
      names = Enum.map(config.functions, & &1.name)
      assert "typeof" in names
      assert "json_extract" in names
      assert "printf" in names
    end

    test "functions have required fields" do
      config = SQLite3.editor_config()

      for func <- config.functions do
        assert is_binary(func.name), "function missing name"
        assert is_binary(func.detail), "function #{func.name} missing detail"
        assert is_binary(func.args), "function #{func.name} missing args"
      end
    end
  end

  describe "built-in dialects return only required editor_config keys" do
    # The built-in Ecto dialects don't set :dialect_spec or
    # :context_schema — their tokenizer comes from the CM6 built-in
    # grammars on the web side, and they're SQL (not JSON DSL) so
    # :context_schema has no meaning for them.
    test "Default / Postgres / MySQL / SQLite3 omit the optional fields" do
      for mod <- [Default, Postgres, MySQL, SQLite3] do
        config = mod.editor_config()

        for key <- @required_keys do
          assert Map.has_key?(config, key), "#{inspect(mod)} missing required key #{key}"
        end

        refute Map.has_key?(config, :dialect_spec),
               "#{inspect(mod)} unexpectedly defined :dialect_spec"

        refute Map.has_key?(config, :context_schema),
               "#{inspect(mod)} unexpectedly defined :context_schema"
      end
    end
  end
end
