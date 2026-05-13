defmodule Lotus.PreflightTest do
  use Lotus.Case
  use Mimic
  alias Lotus.Preflight
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  @pg_adapter EctoAdapter.wrap("postgres", Lotus.Test.Repo)
  @sqlite_adapter EctoAdapter.wrap("sqlite", Lotus.Test.SqliteRepo)
  @mysql_adapter EctoAdapter.wrap("mysql", Lotus.Test.MysqlRepo)

  describe "adapter detection" do
    test "correctly identifies PostgreSQL adapter" do
      assert :ok = Preflight.authorize(@pg_adapter, Statement.new("SELECT 1", []))
    end

    @tag :sqlite
    test "correctly identifies SQLite adapter" do
      assert :ok = Preflight.authorize(@sqlite_adapter, Statement.new("SELECT 1", []))
    end

    @tag :mysql
    test "correctly identifies MySQL adapter" do
      assert :ok = Preflight.authorize(@mysql_adapter, Statement.new("SELECT 1", []))
    end
  end

  describe "unrestricted adapter behavior" do
    setup :set_mimic_from_context

    setup do
      Mimic.copy(Lotus.Config)
      :ok
    end

    test "blocks queries when adapter returns {:unrestricted, _} and opt-in is off" do
      stub(Lotus.Config, :allow_unrestricted_resources?, fn _name -> false end)

      unknown_adapter = %Lotus.Source.Adapter{
        name: "unknown",
        module: Lotus.Test.NoOpAdapter,
        state: nil,
        source_type: :other
      }

      assert {:error, msg} =
               Preflight.authorize(unknown_adapter, Statement.new("SELECT * FROM anything"))

      assert msg =~ "Preflight blocked"
      assert msg =~ "allow_unrestricted_resources"
    end

    test "blocks queries when adapter does not implement extract_accessed_resources and opt-in is off" do
      stub(Lotus.Config, :allow_unrestricted_resources?, fn _name -> false end)

      stub_adapter = %Lotus.Source.Adapter{
        name: "stub",
        module: Lotus.Test.StubAdapter,
        state: nil,
        source_type: :other
      }

      assert {:error, msg} =
               Preflight.authorize(stub_adapter, Statement.new("SELECT * FROM anything"))

      assert msg =~ "Preflight blocked"
    end

    test "allows queries when adapter returns {:unrestricted, _} and source is opted in" do
      stub(Lotus.Config, :allow_unrestricted_resources?, fn "trusted" -> true end)

      trusted_adapter = %Lotus.Source.Adapter{
        name: "trusted",
        module: Lotus.Test.NoOpAdapter,
        state: nil,
        source_type: :other
      }

      assert :ok =
               Preflight.authorize(trusted_adapter, Statement.new("SELECT * FROM anything"))
    end

    test "allows queries when adapter omits extract_accessed_resources and source is opted in" do
      stub(Lotus.Config, :allow_unrestricted_resources?, fn "trusted" -> true end)

      trusted_adapter = %Lotus.Source.Adapter{
        name: "trusted",
        module: Lotus.Test.StubAdapter,
        state: nil,
        source_type: :other
      }

      assert :ok =
               Preflight.authorize(trusted_adapter, Statement.new("SELECT * FROM anything"))
    end
  end
end
