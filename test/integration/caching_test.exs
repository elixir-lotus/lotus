defmodule Lotus.Integration.CachingTest do
  use Lotus.Case
  use Mimic

  alias Lotus.{Cache, Config, Fixtures}
  alias Lotus.Cache.ETS
  alias Lotus.Storage.Query
  alias Repo

  setup do
    Mimic.copy(Lotus.Config)
    Mimic.copy(Lotus.Cache)

    start_supervised!(ETS)

    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> "integration_test" end)
    |> stub(:cache_config, fn ->
      %{
        adapter: ETS,
        namespace: "integration_test",
        profiles: %{
          results: [ttl_ms: 30_000],
          options: [ttl_ms: 300_000],
          schema: [ttl_ms: 3_600_000]
        },
        default_profile: :results,
        default_ttl_ms: 60_000
      }
    end)
    |> stub(:default_cache_profile, fn -> :results end)
    |> stub(:cache_profile_settings, fn profile ->
      case profile do
        :results -> [ttl_ms: 30_000]
        :options -> [ttl_ms: 300_000]
        :schema -> [ttl_ms: 3_600_000]
        _ -> [ttl_ms: 60_000]
      end
    end)

    :ok
  end

  describe "run_sql/3 caching scenarios" do
    setup do
      user = Fixtures.insert_user(%{name: "Cache Test User", email: "cache@test.com"})
      %{user: user}
    end

    test "caching works by default when adapter configured", %{user: user} do
      sql = "SELECT name, email FROM test_users WHERE id = $1"

      assert {:ok, result1} = Lotus.run_sql(sql, [user.id])
      assert [["Cache Test User", "cache@test.com"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_sql(sql, [user.id])

      assert result1.rows == result2.rows
      assert result1.columns == result2.columns
      assert [["Cache Test User", "cache@test.com"]] = result2.rows
    end

    test "explicit profile selection uses correct TTL", %{user: user} do
      expect(Cache, :get_or_store, 2, fn key, ttl, fun, opts ->
        assert ttl == 300_000
        Cache.ETS.get_or_store(key, ttl, fun, opts)
      end)

      sql = "SELECT name FROM test_users WHERE id = $1"

      assert {:ok, result1} = Lotus.run_sql(sql, [user.id], cache: [profile: :options])
      assert [["Cache Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_sql(sql, [user.id], cache: [profile: :options])

      assert result1.rows == result2.rows
      assert result1.columns == result2.columns
      assert [["Cache Test User"]] = result2.rows
    end

    test "TTL override uses specified TTL", %{user: user} do
      expect(Cache, :get_or_store, 2, fn key, ttl, fun, opts ->
        assert ttl == 5_000
        Cache.ETS.get_or_store(key, ttl, fun, opts)
      end)

      sql = "SELECT email FROM test_users WHERE id = $1"

      assert {:ok, result1} = Lotus.run_sql(sql, [user.id], cache: [ttl_ms: 5_000])
      assert [["cache@test.com"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_sql(sql, [user.id], cache: [ttl_ms: 5_000])

      assert result1.rows == result2.rows
      assert result1.columns == result2.columns
      assert [["cache@test.com"]] = result2.rows
    end

    test "refresh mode updates cache with fresh data", %{user: user} do
      sql = "SELECT name FROM test_users WHERE id = $1"

      assert {:ok, result1} = Lotus.run_sql(sql, [user.id])
      assert [["Cache Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_sql(sql, [user.id], cache: :refresh)
      assert [] = result2.rows

      assert {:ok, result3} = Lotus.run_sql(sql, [user.id])
      assert [] = result3.rows
    end

    test "refresh mode with profile override uses profile TTL" do
      expect(Cache, :put, fn key, val, ttl, opts ->
        assert ttl == 300_000
        Cache.ETS.put(key, val, ttl, opts)
      end)

      sql = "SELECT 'profile_refresh' as data"

      assert {:ok, result} = Lotus.run_sql(sql, [], cache: [:refresh, profile: :options])
      assert [["profile_refresh"]] = result.rows
    end

    test "tagged entries can be invalidated", %{user: user} do
      sql = "SELECT name FROM test_users WHERE id = $1"

      assert {:ok, result1} = Lotus.run_sql(sql, [user.id], cache: [tags: ["user:#{user.id}"]])
      assert [["Cache Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_sql(sql, [user.id], cache: [tags: ["user:#{user.id}"]])
      assert result1.rows == result2.rows

      Cache.invalidate_tags(["user:#{user.id}"])

      assert {:ok, result3} = Lotus.run_sql(sql, [user.id], cache: [tags: ["user:#{user.id}"]])
      assert [] = result3.rows
    end

    test "bypass cache leaves existing cache intact", %{user: user} do
      sql = "SELECT name FROM test_users WHERE id = $1"

      assert {:ok, result1} = Lotus.run_sql(sql, [user.id])
      assert [["Cache Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_sql(sql, [user.id], cache: :bypass)
      assert [] = result2.rows

      assert {:ok, result3} = Lotus.run_sql(sql, [user.id])
      assert [["Cache Test User"]] = result3.rows
    end

    test "max_bytes option is passed to cache layer", %{user: user} do
      expect(Cache, :get_or_store, fn key, ttl, fun, opts ->
        assert Keyword.get(opts, :max_bytes) == 100
        Cache.ETS.get_or_store(key, ttl, fun, opts)
      end)

      sql = "SELECT name FROM test_users WHERE id = $1"
      assert {:ok, _result} = Lotus.run_sql(sql, [user.id], cache: [max_bytes: 100])
    end

    test "compress option is passed to cache layer", %{user: user} do
      expect(Cache, :get_or_store, fn key, ttl, fun, opts ->
        assert Keyword.get(opts, :compress) == false
        Cache.ETS.get_or_store(key, ttl, fun, opts)
      end)

      sql = "SELECT name FROM test_users WHERE id = $1"
      assert {:ok, _result} = Lotus.run_sql(sql, [user.id], cache: [compress: false])
    end
  end

  describe "run_query/2 caching scenarios" do
    setup do
      user = Fixtures.insert_user(%{name: "Query Test User", email: "query@test.com"})
      %{user: user}
    end

    test "caching works by default", %{user: user} do
      query = %Query{
        statement: "SELECT name FROM test_users WHERE id = {{user_id}}",
        variables: [],
        data_repo: nil
      }

      assert {:ok, result1} = Lotus.run_query(query, vars: %{"user_id" => user.id})
      assert [["Query Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.run_query(query, vars: %{"user_id" => user.id})
      assert result1.rows == result2.rows
      assert [["Query Test User"]] = result2.rows
    end

    test "refresh mode updates cache with fresh data", %{user: user} do
      query = %Query{
        statement: "SELECT name FROM test_users WHERE id = {{user_id}}",
        variables: [],
        data_repo: nil
      }

      assert {:ok, result1} = Lotus.run_query(query, vars: %{"user_id" => user.id})
      assert [["Query Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} =
               Lotus.run_query(query, vars: %{"user_id" => user.id}, cache: :refresh)

      assert [] = result2.rows

      # Now normal cache read should return the refreshed (empty) result
      assert {:ok, result3} = Lotus.run_query(query, vars: %{"user_id" => user.id})
      assert [] = result3.rows
    end

    test "bypass cache leaves existing cache intact", %{user: user} do
      query = %Query{
        statement: "SELECT name FROM test_users WHERE id = {{user_id}}",
        variables: [],
        data_repo: nil
      }

      assert {:ok, result1} = Lotus.run_query(query, vars: %{"user_id" => user.id})
      assert [["Query Test User"]] = result1.rows

      Repo.delete!(user)

      assert {:ok, result2} =
               Lotus.run_query(query, vars: %{"user_id" => user.id}, cache: :bypass)

      assert [] = result2.rows

      # Normal cache read should still return the original cached result
      assert {:ok, result3} = Lotus.run_query(query, vars: %{"user_id" => user.id})
      assert [["Query Test User"]] = result3.rows
    end

    test "cache options are passed through run_query", %{user: user} do
      expect(Cache, :get_or_store, fn key, ttl, fun, opts ->
        assert Keyword.get(opts, :max_bytes) == 200
        assert Keyword.get(opts, :compress) == false
        Cache.ETS.get_or_store(key, ttl, fun, opts)
      end)

      query = %Query{
        statement: "SELECT name FROM test_users WHERE id = {{user_id}}",
        variables: [],
        data_repo: nil
      }

      assert {:ok, _result} =
               Lotus.run_query(query,
                 vars: %{"user_id" => user.id},
                 cache: [max_bytes: 200, compress: false]
               )
    end
  end

  describe "Schema caching scenarios" do
    test "get_table_stats caching works with real data changes" do
      user = Fixtures.insert_user(%{name: "Stats Test User", email: "stats@test.com"})

      assert {:ok, result1} = Lotus.get_table_stats("postgres", "test_users")
      assert %{row_count: count1} = result1
      assert count1 >= 1

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.get_table_stats("postgres", "test_users")
      assert result1.row_count == result2.row_count
      # Still cached value
      assert result2.row_count == count1
    end

    test "get_table_stats bypass mode skips cache" do
      user = Fixtures.insert_user(%{name: "Bypass Test User", email: "bypass@test.com"})

      assert {:ok, result1} = Lotus.get_table_stats("postgres", "test_users")
      assert %{row_count: count1} = result1

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.get_table_stats("postgres", "test_users", cache: :bypass)
      assert result2.row_count == count1 - 1

      assert {:ok, result3} = Lotus.get_table_stats("postgres", "test_users")
      assert result3.row_count == count1
    end

    test "get_table_stats refresh mode updates cache with fresh data" do
      user = Fixtures.insert_user(%{name: "Refresh Test User", email: "refresh@test.com"})

      assert {:ok, result1} = Lotus.get_table_stats("postgres", "test_users")
      assert %{row_count: count1} = result1

      Repo.delete!(user)

      assert {:ok, result2} = Lotus.get_table_stats("postgres", "test_users", cache: :refresh)
      assert result2.row_count == count1 - 1

      assert {:ok, result3} = Lotus.get_table_stats("postgres", "test_users")
      assert result3.row_count == count1 - 1
    end

    test "schema functions respect cache profile override" do
      expect(Cache, :get_or_store, fn key, ttl, fun, opts ->
        assert ttl == 300_000
        Cache.ETS.get_or_store(key, ttl, fun, opts)
      end)

      assert {:ok, _result} = Lotus.list_tables("postgres", cache: [profile: :options])
    end
  end
end
