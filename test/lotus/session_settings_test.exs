defmodule Lotus.SessionSettingsTest do
  @moduledoc """
  A statement's `:session` settings, set by a `:before_query` plug, are
  applied to the connection inside the statement's transaction by an adapter
  that declares `Lotus.Source.Adapter.Session`, key the result cache, and
  carry over to the count run of a page. A source that cannot apply them
  refuses the statement.
  """

  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Cache.ETS
  alias Lotus.{Config, Middleware}
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  @setting "SELECT current_setting('app.tenant_id', true) AS tenant"

  defmodule TenantSessionPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement, context: %{session: session}} = payload, _opts),
      do: {:cont, %{payload | statement: %{statement | session: session}}}

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule CaptureExecutePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement} = payload, _opts) do
      send(self(), {:before_execute, statement})
      {:cont, payload}
    end
  end

  setup do
    Middleware.compile(%{before_query: [{TenantSessionPlug, []}]})
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)
    :ok
  end

  defp run(sql, session, opts \\ []) do
    Lotus.run_statement(sql, [], [repo: "postgres", context: %{session: session}] ++ opts)
  end

  describe "on PostgreSQL" do
    test "the settings reach the connection for the statement" do
      assert {:ok, %{rows: [["acme"]]}} = run(@setting, %{"app.tenant_id" => "acme"})
      assert {:ok, %{rows: [["globex"]]}} = run(@setting, %{"app.tenant_id" => "globex"})
    end

    test "integers and booleans are applied as strings" do
      adapter = EctoAdapter.wrap("postgres", Lotus.Test.Repo)

      statement = %Statement{
        body: "SELECT current_setting('app.user_id', true), current_setting('app.admin', true)",
        session: %{"app.user_id" => 42, "app.admin" => false}
      }

      assert {:ok, %{rows: [["42", "false"]]}} = Runner.run_statement(adapter, statement)
    end

    test "a built-in setting is refused and the statement does not run" do
      for name <- ["transaction_read_only", "role", "search_path"] do
        assert {:error, message} = run(@setting, %{name => "off"})
        assert message =~ "custom settings named prefix.name"
      end
    end

    test "a value that is not a string, an integer or a boolean is refused" do
      assert {:error, message} = run(@setting, %{"app.tenant_id" => %{id: 1}})
      assert message =~ "string names and string, integer or boolean values"
    end

    test "a read-write statement may not change the settings it runs under" do
      session = %{"app.tenant_id" => "acme"}

      for sql <- [
            "SELECT set_config('app.tenant_id', 'globex', true), #{String.replace(@setting, "SELECT ", "")}",
            "WITH x AS MATERIALIZED (SELECT pg_catalog.set_config('app.tenant_id', 'globex', true)) " <>
              "SELECT * FROM x",
            ~S|SELECT U&"set\005fconfig"('app.tenant_id', 'globex', true)|,
            "SET app.tenant_id = 'globex'",
            "RESET app.tenant_id"
          ] do
        assert {:error, "A statement with session settings may not change settings"} =
                 run(sql, session, read_only: false),
               sql
      end

      assert {:ok, %{rows: [["acme"]]}} = run(@setting, session, read_only: false)
    end

    test "a read-write statement without settings may still change one" do
      assert {:ok, %{rows: [["globex"]]}} =
               Lotus.run_statement("SELECT set_config('app.tenant_id', 'globex', true)", [],
                 repo: "postgres",
                 read_only: false
               )
    end

    test "the Postgres adapter declares the capability; the others do not" do
      assert Adapter.capability?(EctoAdapter.wrap("postgres", Lotus.Test.Repo), :session)
      refute Adapter.capability?(EctoAdapter.wrap("sqlite", Lotus.Test.SqliteRepo), :session)
      refute Adapter.capability?(EctoAdapter.wrap("mysql", Lotus.Test.MysqlRepo), :session)
    end
  end

  @tag :sqlite
  test "a source that cannot apply settings refuses the statement" do
    assert {:error, message} =
             Lotus.run_statement("SELECT 1", [],
               repo: "sqlite",
               context: %{session: %{"app.tenant_id" => "acme"}}
             )

    assert message =~ "cannot apply session settings"

    assert {:ok, _} = Lotus.run_statement("SELECT 1", [], repo: "sqlite", context: %{})
  end

  test "the count run of a page keeps the session" do
    Middleware.compile(%{
      before_query: [{TenantSessionPlug, []}],
      before_execute: [{CaptureExecutePlug, []}]
    })

    sql = "SELECT x FROM (VALUES (1), (2), (3)) AS v(x)"

    assert {:ok, %{meta: %{total_count: 3}}} =
             run(sql, %{"app.tenant_id" => "acme"}, window: [limit: 2, count: :exact])

    assert_received {:before_execute, %Statement{session: %{"app.tenant_id" => "acme"}}}
    assert_received {:before_execute, %Statement{session: %{"app.tenant_id" => "acme"}} = count}
    assert count.body =~ ~r/COUNT\(\*\)/
  end

  describe "with the result cache" do
    setup do
      clear_cache_tables()
      on_exit(&clear_cache_tables/0)

      Config
      |> stub(:cache_adapter, fn -> {:ok, ETS} end)
      |> stub(:cache_namespace, fn -> "session_settings_test" end)
      |> stub(:default_cache_profile, fn -> :results end)
      |> stub(:cache_profile_settings, fn _profile -> [ttl_ms: 30_000] end)

      :ok
    end

    test "each session has its own entry" do
      assert {:ok, %{rows: [["acme"]]}} = run(@setting, %{"app.tenant_id" => "acme"})
      assert {:ok, %{rows: [["globex"]]}} = run(@setting, %{"app.tenant_id" => "globex"})
      assert {:ok, %{rows: [["acme"]]}} = run(@setting, %{"app.tenant_id" => "acme"})
    end
  end

  defp clear_cache_tables do
    for table <- [:lotus_cache, :lotus_cache_tags] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end
end
