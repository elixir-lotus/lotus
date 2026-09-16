defmodule Lotus.Source.Adapters.Ecto.DynamicRepoTest do
  use Lotus.Case, async: true

  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Source.Adapters.Postgres
  alias Lotus.Source.Adapters.SQLite3
  alias Lotus.Source.Registry
  alias Lotus.Test.Repo
  alias Lotus.Test.SqliteRepo

  defp start_dynamic_repo(opts \\ []) do
    opts = Keyword.merge([name: nil, pool: DBConnection.ConnectionPool, pool_size: 1], opts)
    id = {Repo, System.unique_integer([:positive])}
    start_supervised!(Supervisor.child_spec({Repo, opts}, id: id))
  end

  defp backend_pid(adapter) do
    {:ok, %{rows: [[pid]]}} = Adapter.execute_query(adapter, "SELECT pg_backend_pid()", [], [])
    pid
  end

  defp sandbox_backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  describe "wrap/2 with a dynamic repo" do
    test "the base adapter routes the map state to the dialect adapter of the repo module" do
      pid = start_dynamic_repo()

      adapter = EctoAdapter.wrap("tenant", %{repo: Repo, dynamic: pid})

      assert %Adapter{
               name: "tenant",
               module: Postgres,
               state: %{repo: Repo, dynamic: ^pid},
               source_type: :postgres
             } = adapter
    end

    test "the dialect adapter accepts the map state directly" do
      adapter = Postgres.wrap("tenant", %{repo: Repo, dynamic: :tenant_repo})

      assert adapter.module == Postgres
      assert adapter.state == %{repo: Repo, dynamic: :tenant_repo}
      assert adapter.source_type == :postgres
    end

    test "raises when the repo module is not an Ecto repo" do
      assert_raise ArgumentError, ~r/does not export __adapter__\/0/, fn ->
        EctoAdapter.wrap("tenant", %{repo: NotARepo, dynamic: self()})
      end
    end

    test "raises when the state is neither a module nor a dynamic repo map" do
      assert_raise ArgumentError, ~r/%\{repo: module, dynamic: pid \| name\}/, fn ->
        Postgres.wrap("tenant", %{repo: Repo})
      end

      assert_raise ArgumentError, fn ->
        Postgres.wrap("tenant", %{repo: Repo, dynamic: "not a target"})
      end
    end
  end

  describe "can_handle?/1" do
    test "the dialect adapter claims the map form of its own repo module" do
      assert Postgres.can_handle?(%{repo: Repo, dynamic: self()})
      refute Postgres.can_handle?(%{repo: SqliteRepo, dynamic: self()})
      assert SQLite3.can_handle?(%{repo: SqliteRepo, dynamic: self()})
    end

    test "the base adapter claims the map form of any Ecto repo" do
      assert EctoAdapter.can_handle?(%{repo: Repo, dynamic: self()})
      refute EctoAdapter.can_handle?(%{repo: NotARepo, dynamic: self()})
    end
  end

  describe "with_repo/2" do
    test "runs the function with the repo module for a static repo" do
      assert EctoAdapter.with_repo(Repo, & &1) == Repo
    end

    test "points the repo module at the dynamic process for the duration of the call" do
      pid = start_dynamic_repo()

      assert Repo.get_dynamic_repo() == Repo

      assert EctoAdapter.with_repo(%{repo: Repo, dynamic: pid}, fn repo ->
               assert repo == Repo
               Repo.get_dynamic_repo()
             end) == pid

      assert Repo.get_dynamic_repo() == Repo
    end

    test "restores the previous dynamic repo after the call" do
      pid = start_dynamic_repo()
      other = start_dynamic_repo()
      Repo.put_dynamic_repo(other)

      EctoAdapter.with_repo(%{repo: Repo, dynamic: pid}, fn _ -> :ok end)

      assert Repo.get_dynamic_repo() == other
    end

    test "restores the previous dynamic repo when the function raises" do
      pid = start_dynamic_repo()

      assert_raise RuntimeError, "boom", fn ->
        EctoAdapter.with_repo(%{repo: Repo, dynamic: pid}, fn _ -> raise "boom" end)
      end

      assert Repo.get_dynamic_repo() == Repo
    end
  end

  describe "callbacks against a dynamic repo" do
    setup do
      pid = start_dynamic_repo()
      {:ok, adapter: Postgres.wrap("tenant", %{repo: Repo, dynamic: pid})}
    end

    test "execute_query/4 runs on the dynamic process", %{adapter: adapter} do
      assert backend_pid(adapter) != sandbox_backend_pid()
      assert Repo.get_dynamic_repo() == Repo
    end

    test "transaction/3 hands the repo module to the function on the dynamic process",
         %{adapter: adapter} do
      assert {:ok, pid} =
               Adapter.transaction(
                 adapter,
                 fn repo ->
                   %{rows: [[pid]]} = repo.query!("SELECT pg_backend_pid()")
                   pid
                 end,
                 []
               )

      assert pid != sandbox_backend_pid()
    end

    test "introspection runs on the dynamic process", %{adapter: adapter} do
      assert {:ok, schemas} = Adapter.list_schemas(adapter)
      assert "public" in schemas

      assert {:ok, tables} = Adapter.list_tables(adapter, ["public"], include_views: false)
      assert is_list(tables)

      assert {:ok, columns} = Adapter.describe_table(adapter, "public", "lotus_queries")
      assert Enum.any?(columns, &(&1.name == "id"))
    end

    test "health_check/1 reaches the dynamic process", %{adapter: adapter} do
      assert :ok = Adapter.health_check(adapter)
    end

    test "query_plan/3 runs on the dynamic process", %{adapter: adapter} do
      statement = Lotus.Query.Statement.new("SELECT 1")
      assert {:ok, _plan} = Adapter.query_plan(adapter, statement, [])
    end
  end

  describe "a dynamic repo named through the registry" do
    test "resolves the via tuple to the running process" do
      name = Registry.via(Postgres, "tenant-#{System.unique_integer([:positive])}")
      start_dynamic_repo(name: name)
      adapter = Postgres.wrap("tenant", %{repo: Repo, dynamic: name})

      assert :ok = Adapter.health_check(adapter)
      assert backend_pid(adapter) != sandbox_backend_pid()
    end

    test "reports an error when the process is not running" do
      name = Registry.via(Postgres, "tenant-#{System.unique_integer([:positive])}")
      adapter = Postgres.wrap("tenant", %{repo: Repo, dynamic: name})

      assert {:error, message} = Adapter.health_check(adapter)
      assert message =~ "is not running"
      assert {:error, _} = Adapter.execute_query(adapter, "SELECT 1", [], [])
      assert {:error, _} = Adapter.list_schemas(adapter)
    end

    test "accepts an atom name" do
      start_dynamic_repo(name: :lotus_dynamic_repo_test)
      adapter = Postgres.wrap("tenant", %{repo: Repo, dynamic: :lotus_dynamic_repo_test})

      assert :ok = Adapter.health_check(adapter)
    end
  end
end
