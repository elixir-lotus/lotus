defmodule Lotus.CacheRulesTest do
  @moduledoc """
  A cached result or discovery list was checked, and filtered or masked,
  under the visibility rules of the call that stored it. It is served only
  while the caller's rules still have the same fingerprint (#326), which
  costs no database query: a hit under unchanged rules executes nothing.
  """

  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Cache.ETS
  alias Lotus.Config
  alias Lotus.Test.Schemas.User
  alias Lotus.Visibility.Matcher

  defmodule HidingResolver do
    @moduledoc false
    @behaviour Lotus.Visibility.Resolver

    alias Lotus.Visibility.Resolvers.Static

    @impl true
    defdelegate schema_rules_for(name, scope), to: Static
    @impl true
    defdelegate table_rules_for(name, scope), to: Static
    @impl true
    defdelegate column_rules_for(name, scope), to: Static
    @impl true
    def source_visible?(_name, _scope), do: false
  end

  @statement "SELECT name, email FROM test_users ORDER BY name"
  @mask_email %{
    column: [{"public", "test_users", "email", [action: :mask, mask: {:fixed, "REDACTED"}]}]
  }

  setup do
    clear_cache_tables()
    on_exit(&clear_cache_tables/0)

    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> "cache_rules_test" end)
    |> stub(:default_cache_profile, fn -> :results end)
    |> stub(:cache_profile_settings, fn _profile -> [ttl_ms: 30_000] end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test", age: 36})

    :ok
  end

  defp clear_cache_tables do
    for table <- [:lotus_cache, :lotus_cache_tags] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  defp rules(rules), do: stub(Config, :visibility_for_source_name, fn _source -> rules end)

  defp run(sql \\ @statement), do: Lotus.run_statement(sql, [], repo: "postgres")

  # `[:lotus, :query, :stop]` fires for an execution and not for a hit.
  defp executions(fun) do
    ref = make_ref()
    pid = self()
    handler = inspect(ref)

    :telemetry.attach(
      handler,
      [:lotus, :query, :stop],
      fn _event, _measurements, _metadata, _config -> send(pid, {ref, :executed}) end,
      nil
    )

    try do
      result = fun.()
      {result, count(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp count(ref, n) do
    receive do
      {^ref, :executed} -> count(ref, n + 1)
    after
      0 -> n
    end
  end

  describe "a cached result" do
    test "is served from the cache while the rules are unchanged" do
      rules(%{})
      assert {{:ok, _}, 1} = executions(&run/0)
      assert {{:ok, %{rows: [["Ada", "ada@example.test"]]}}, 0} = executions(&run/0)
    end

    test "is not served once a column policy masks one of its columns" do
      rules(%{})
      assert {:ok, %{rows: [["Ada", "ada@example.test"]]}} = run()

      rules(@mask_email)
      assert {{:ok, %{rows: [["Ada", "REDACTED"]]}}, 1} = executions(&run/0)

      # The entry was replaced, and is served under the new rules.
      assert {{:ok, %{rows: [["Ada", "REDACTED"]]}}, 0} = executions(&run/0)
    end

    test "is not served once a policy would refuse the statement" do
      rules(%{})
      assert {:ok, _} = run("SELECT email AS e FROM test_users")

      rules(@mask_email)

      assert {:error, "Query uses protected column email" <> _} =
               run("SELECT email AS e FROM test_users")
    end

    test "is not served once a table rule denies its table" do
      rules(%{})
      assert {:ok, _} = run()

      rules(%{table: [deny: [{"public", "test_users"}]]})
      assert {:error, "Query touches blocked table(s): public.test_users"} = run()
    end

    test "is not served once the source is hidden from the scope" do
      rules(%{})
      assert {:ok, _} = run()

      stub(Config, :visibility_resolver, fn -> HidingResolver end)
      assert {:error, ~s(Data source "postgres" is not available)} = run()
    end
  end

  describe "a cached discovery list" do
    test "is not served once a table rule hides a table in it" do
      rules(%{})
      assert {:ok, tables} = Lotus.list_tables("postgres")
      assert {"public", "test_users"} in tables

      rules(%{table: [deny: [{"public", "test_users"}]]})
      assert {:ok, tables} = Lotus.list_tables("postgres")
      refute {"public", "test_users"} in tables
    end

    test "is not served once a column policy changes a description" do
      rules(%{})
      assert {:ok, columns} = Lotus.describe_table("postgres", "test_users")
      assert Enum.find(columns, &(&1.name == "email"))[:visibility] == nil

      rules(@mask_email)
      assert {:ok, columns} = Lotus.describe_table("postgres", "test_users")
      assert %{action: :mask} = Enum.find(columns, &(&1.name == "email")).visibility
    end
  end

  describe "the rules fingerprint" do
    test "is the same for the same rules, compiled apart" do
      rules = %{table: [deny: [{"public", ~r/^secret_/}, "api_keys"]], column: [{"ssn", :omit}]}

      assert Matcher.fingerprint(Lotus.Visibility.compile(rules)) ==
               Matcher.fingerprint(Lotus.Visibility.compile(rules))
    end

    test "differs when a rule changes" do
      a = Lotus.Visibility.compile(%{table: [deny: [{"public", ~r/^secret_/}]]})
      b = Lotus.Visibility.compile(%{table: [deny: [{"public", ~r/^secret/}]]})

      refute Matcher.fingerprint(a) == Matcher.fingerprint(b)
      refute Matcher.fingerprint(a) == Matcher.fingerprint(Matcher.deny_all())
    end
  end
end
