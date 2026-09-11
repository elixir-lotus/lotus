defmodule Lotus.SourcesTest do
  use Lotus.Case, async: true

  alias Lotus.Source
  alias Lotus.Source.Adapter

  describe "resolve!/2" do
    test "resolves with string repo_opt" do
      adapter = Source.resolve!("postgres", nil)
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
      assert adapter.state == Lotus.Test.Repo
      assert adapter.source_type == :postgres
    end

    test "resolves with another string repo_opt" do
      adapter = Source.resolve!("sqlite", nil)
      assert %Adapter{} = adapter
      assert adapter.name == "sqlite"
      assert adapter.state == Lotus.Test.SqliteRepo
    end

    test "resolves with module repo_opt" do
      adapter = Source.resolve!(Lotus.Test.Repo, nil)
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
      assert adapter.state == Lotus.Test.Repo
    end

    test "resolves with different module repo_opt" do
      adapter = Source.resolve!(Lotus.Test.SqliteRepo, nil)
      assert %Adapter{} = adapter
      assert adapter.name == "sqlite"
      assert adapter.state == Lotus.Test.SqliteRepo
    end

    test "falls back to string q_repo when repo_opt is nil" do
      adapter = Source.resolve!(nil, "mysql")
      assert %Adapter{} = adapter
      assert adapter.name == "mysql"
      assert adapter.state == Lotus.Test.MysqlRepo
    end

    test "falls back to module q_repo when repo_opt is nil" do
      adapter = Source.resolve!(nil, Lotus.Test.MysqlRepo)
      assert %Adapter{} = adapter
      assert adapter.name == "mysql"
      assert adapter.state == Lotus.Test.MysqlRepo
    end

    test "falls back to default repo when both are nil" do
      adapter = Source.resolve!(nil, nil)
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
      assert adapter.state == Lotus.Test.Repo
    end

    test "repo_opt takes precedence over q_repo" do
      adapter = Source.resolve!("sqlite", "mysql")
      assert %Adapter{} = adapter
      assert adapter.name == "sqlite"
      assert adapter.state == Lotus.Test.SqliteRepo
    end

    test "repo_opt module takes precedence over q_repo string" do
      adapter = Source.resolve!(Lotus.Test.SqliteRepo, "mysql")
      assert %Adapter{} = adapter
      assert adapter.name == "sqlite"
      assert adapter.state == Lotus.Test.SqliteRepo
    end

    test "raises when string repo_opt is not configured" do
      assert_raise ArgumentError, ~r/not configured/, fn ->
        Source.resolve!("unknown", nil)
      end
    end

    test "raises when string q_repo is not configured and repo_opt is nil" do
      assert_raise ArgumentError, ~r/not configured/, fn ->
        Source.resolve!(nil, "nonexistent")
      end
    end

    test "loaded but unconfigured module in repo_opt raises" do
      # String is a real loaded module but not in data_sources — the resolver
      # commits to it and surfaces the error rather than silently masking it.
      assert_raise ArgumentError, ~r/not configured/, fn ->
        Source.resolve!(String, "sqlite")
      end
    end

    test "unloaded atom in repo_opt falls through to q_repo" do
      adapter = Source.resolve!(:typoed_name, "sqlite")
      assert %Adapter{} = adapter
      assert adapter.name == "sqlite"
      assert adapter.state == Lotus.Test.SqliteRepo
    end

    test "unloaded atoms in both positions fall through to default" do
      adapter = Source.resolve!(:typoed_one, :typoed_two)
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
      assert adapter.state == Lotus.Test.Repo
    end

    test "handles invalid types gracefully" do
      adapter = Source.resolve!(123, :"Elixir.Nonexistent.Module")
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
      assert adapter.state == Lotus.Test.Repo
    end
  end

  describe "name_from_module!/1" do
    test "returns configured name for a repo module" do
      assert Source.name_from_module!(Lotus.Test.Repo) == "postgres"
      assert Source.name_from_module!(Lotus.Test.SqliteRepo) == "sqlite"
      assert Source.name_from_module!(Lotus.Test.MysqlRepo) == "mysql"
    end

    test "raises for unconfigured repo module" do
      defmodule UnknownRepo do
        def __adapter__, do: Ecto.Adapters.Postgres
      end

      assert_raise ArgumentError, fn ->
        Source.name_from_module!(UnknownRepo)
      end
    end
  end

  describe "source_type/1" do
    test "detects postgres adapter from repo name" do
      assert Source.source_type("postgres") == :postgres
    end

    test "detects sqlite adapter from repo name" do
      assert Source.source_type("sqlite") == :sqlite
    end

    test "detects mysql adapter from repo name" do
      assert Source.source_type("mysql") == :mysql
    end

    test "detects postgres adapter from repo module" do
      assert Source.source_type(Lotus.Test.Repo) == :postgres
    end

    test "detects sqlite adapter from repo module" do
      assert Source.source_type(Lotus.Test.SqliteRepo) == :sqlite
    end

    test "detects mysql adapter from repo module" do
      assert Source.source_type(Lotus.Test.MysqlRepo) == :mysql
    end

    test "detects source type from adapter struct" do
      adapter = Source.resolve!("postgres", nil)
      assert Source.source_type(adapter) == :postgres
    end

    test "raises for unknown repo name" do
      assert_raise ArgumentError, ~r/Data source \"unknown\" not configured/, fn ->
        Source.source_type("unknown")
      end
    end

    test "raises for unconfigured repo module" do
      defmodule CustomAdapterRepo do
        def __adapter__ do
          Module.concat(["UnknownAdapter"])
        end
      end

      assert_raise ArgumentError, ~r/not configured/, fn ->
        Source.source_type(CustomAdapterRepo)
      end
    end
  end

  describe "list_sources/0" do
    test "returns all configured sources as adapters" do
      adapters = Source.list_sources()
      names = Enum.map(adapters, & &1.name) |> Enum.sort()

      assert "mysql" in names
      assert "postgres" in names
      assert "sqlite" in names

      Enum.each(adapters, fn adapter ->
        assert %Adapter{} = adapter
      end)
    end
  end

  describe "get_source!/1" do
    test "returns adapter for configured name" do
      adapter = Source.get_source!("postgres")
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
    end

    test "raises for unknown name" do
      assert_raise ArgumentError, ~r/Data source \"unknown\" not configured/, fn ->
        Source.get_source!("unknown")
      end
    end
  end

  describe "default_source/0" do
    test "returns the default source as adapter" do
      adapter = Source.default_source()
      assert %Adapter{} = adapter
      assert adapter.name == "postgres"
    end
  end

  describe "supports_feature?/2" do
    test "postgres features" do
      assert Source.supports_feature?("postgres", :search_path) == true
      assert Source.supports_feature?("postgres", :make_interval) == true
      assert Source.supports_feature?("postgres", :arrays) == true
      assert Source.supports_feature?("postgres", :json) == true
    end

    test "mysql features" do
      assert Source.supports_feature?("mysql", :search_path) == false
      assert Source.supports_feature?("mysql", :make_interval) == false
      assert Source.supports_feature?("mysql", :arrays) == false
      assert Source.supports_feature?("mysql", :json) == true
    end

    test "sqlite features" do
      assert Source.supports_feature?("sqlite", :search_path) == false
      assert Source.supports_feature?("sqlite", :make_interval) == false
      assert Source.supports_feature?("sqlite", :arrays) == false
      assert Source.supports_feature?("sqlite", :json) == true
    end

    test "unknown feature returns false for all source types" do
      assert Source.supports_feature?("postgres", :unknown_feature) == false
      assert Source.supports_feature?("mysql", :unknown_feature) == false
      assert Source.supports_feature?("sqlite", :unknown_feature) == false
    end

    test "schema_hierarchy feature" do
      assert Source.supports_feature?("postgres", :schema_hierarchy) == true
      assert Source.supports_feature?("mysql", :schema_hierarchy) == false
      assert Source.supports_feature?("sqlite", :schema_hierarchy) == false
    end
  end

  describe "query_language/1" do
    test "returns query language from adapter struct" do
      adapter = Source.resolve!("postgres", nil)
      assert Source.query_language(adapter) == "sql:postgres"
    end

    test "returns query language from source name" do
      assert Source.query_language("postgres") == "sql:postgres"
      assert Source.query_language("mysql") == "sql:mysql"
      assert Source.query_language("sqlite") == "sql:sqlite"
    end
  end

  describe "limit_query/3" do
    test "wraps statement with limit from adapter struct" do
      adapter = Source.resolve!("postgres", nil)
      statement = Lotus.Query.Statement.new("SELECT * FROM users", [:bound])

      assert %Lotus.Query.Statement{body: body, params: params} =
               Source.limit_query(adapter, statement, 10)

      assert body == "SELECT * FROM (SELECT * FROM users) AS limited_query LIMIT 10"
      assert params == [:bound]
    end

    test "wraps statement with limit from source name" do
      statement = Lotus.Query.Statement.new("SELECT * FROM users")

      assert %Lotus.Query.Statement{body: body} = Source.limit_query("postgres", statement, 10)
      assert body == "SELECT * FROM (SELECT * FROM users) AS limited_query LIMIT 10"
    end
  end
end
