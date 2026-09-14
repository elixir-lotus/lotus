defmodule Lotus.Cache.CachexTest do
  use Lotus.Case
  use Mimic

  import Cachex.Spec

  # Using Cache.Cachex as the alias so as to not shadow
  # the Cachex module itself.
  alias Lotus.Cache

  @default_ttl_ms 10_000

  setup_all do
    Lotus.Config
    |> stub(:cache_config, fn ->
      %{
        cachex_opts: [router: router(module: Cachex.Router.Local)]
      }
    end)

    # The app-level Lotus.Cache.ETS adapter owns the :lotus_cache /
    # :lotus_cache_tags ETS tables at all times. Cachex's Eternal manager
    # wants to create those same named tables — so we terminate the ETS
    # adapter for the duration of this module, then restart it on exit so
    # sibling modules that expect the ETS adapter still work.
    :ok = Supervisor.terminate_child(Lotus.Supervisor, Lotus.Cache.ETS)

    on_exit(fn ->
      # Cachex's supervised children are stopped by ExUnit before this
      # runs, so the tables are free for ETS to re-claim.
      {:ok, _pid} = Supervisor.restart_child(Lotus.Supervisor, Lotus.Cache.ETS)
    end)

    for spec <- Cache.Cachex.spec_config() do
      start_link_supervised!(spec)
    end

    :ok
  end

  setup do
    Cachex.clear(:lotus_cache)
    Cachex.clear(:lotus_cache_tags)
    :ok
  end

  describe "get/1" do
    test "returns :miss when key doesn't exist" do
      assert Cache.Cachex.get("nonexistent") == :miss
    end

    test "returns {:ok, value} when key exists and not expired" do
      Cache.Cachex.put("key1", "value1", @default_ttl_ms, [])
      assert Cache.Cachex.get("key1") == {:ok, "value1"}
    end

    test "returns :miss and deletes key when expired" do
      Cache.Cachex.put("expired_key", "value", 1, [])
      Process.sleep(5)
      assert Cache.Cachex.get("expired_key") == :miss
      assert Cache.Cachex.get("expired_key") == :miss
    end

    test "works with complex data structures" do
      data = %{list: [1, 2, 3], map: %{nested: true}, tuple: {:ok, "test"}}
      Cache.Cachex.put("complex", data, @default_ttl_ms, [])
      assert Cache.Cachex.get("complex") == {:ok, data}
    end
  end

  describe "put/4" do
    test "stores value with TTL" do
      assert Cache.Cachex.put("key", "value", @default_ttl_ms, []) == :ok
      assert Cache.Cachex.get("key") == {:ok, "value"}
    end

    test "overwrites existing key" do
      Cache.Cachex.put("key", "old_value", @default_ttl_ms, [])
      Cache.Cachex.put("key", "new_value", @default_ttl_ms, [])
      assert Cache.Cachex.get("key") == {:ok, "new_value"}
    end

    test "respects max_bytes option and doesn't store large values" do
      large_value = String.duplicate("x", 1000)

      assert Cache.Cachex.put("large", large_value, @default_ttl_ms,
               max_bytes: 100,
               compress: false
             ) == :ok

      assert Cache.Cachex.get("large") == :miss
    end

    test "stores value when under max_bytes limit" do
      small_value = "small"
      assert Cache.Cachex.put("small", small_value, @default_ttl_ms, max_bytes: 100) == :ok
      assert Cache.Cachex.get("small") == {:ok, "small"}
    end

    test "uses compression by default" do
      large_data = Enum.to_list(1..1000)
      assert Cache.Cachex.put("compressed", large_data, @default_ttl_ms, []) == :ok
      assert Cache.Cachex.get("compressed") == {:ok, large_data}
    end

    test "can disable compression" do
      data = [1, 2, 3, 4, 5]
      assert Cache.Cachex.put("uncompressed", data, @default_ttl_ms, compress: false) == :ok
      assert Cache.Cachex.get("uncompressed") == {:ok, data}
    end

    test "stores tags when provided" do
      assert Cache.Cachex.put("tagged_key", "value", @default_ttl_ms, tags: ["tag1", "tag2"]) ==
               :ok

      assert Cache.Cachex.get("tagged_key") == {:ok, "value"}
    end
  end

  describe "delete/1" do
    test "deletes existing key" do
      Cache.Cachex.put("key", "value", @default_ttl_ms, [])
      assert Cache.Cachex.get("key") == {:ok, "value"}
      assert Cache.Cachex.delete("key") == :ok
      assert Cache.Cachex.get("key") == :miss
    end

    test "returns :ok even when key doesn't exist" do
      assert Cache.Cachex.delete("nonexistent") == :ok
    end
  end

  describe "touch/2" do
    test "updates TTL for existing key" do
      Cache.Cachex.put("key", "value", 100, [])
      Process.sleep(50)
      assert Cache.Cachex.touch("key", @default_ttl_ms) == :ok
      Process.sleep(100)
      assert Cache.Cachex.get("key") == {:ok, "value"}
    end

    test "returns :ok even when key doesn't exist" do
      assert Cache.Cachex.touch("nonexistent", @default_ttl_ms) == :ok
    end
  end

  describe "get_or_store/4" do
    test "returns cached value when key exists" do
      Cache.Cachex.put("existing", "cached_value", @default_ttl_ms, [])

      result =
        Cache.Cachex.get_or_store("existing", @default_ttl_ms, fn -> "computed_value" end, [])

      assert result == {:ok, "cached_value", :hit}
    end

    test "computes and stores value when key doesn't exist" do
      result =
        Cache.Cachex.get_or_store("new_key", @default_ttl_ms, fn -> "computed_value" end, [])

      assert result == {:ok, "computed_value", :miss}
      assert Cache.Cachex.get("new_key") == {:ok, "computed_value"}
    end
  end

  describe "invalidate_tags/1" do
    test "deletes all keys with matching tags" do
      Cache.Cachex.put("key1", "value1", @default_ttl_ms, tags: ["tag1"])
      Cache.Cachex.put("key2", "value2", @default_ttl_ms, tags: ["tag1", "tag2"])
      Cache.Cachex.put("key3", "value3", @default_ttl_ms, tags: ["tag2"])
      Cache.Cachex.put("key4", "value4", @default_ttl_ms, tags: ["tag3"])

      assert Cache.Cachex.invalidate_tags(["tag1"]) == :ok

      assert Cache.Cachex.get("key1") == :miss
      assert Cache.Cachex.get("key2") == :miss
      assert Cache.Cachex.get("key3") == {:ok, "value3"}
      assert Cache.Cachex.get("key4") == {:ok, "value4"}
    end

    test "handles multiple tags in single call" do
      Cache.Cachex.put("key1", "value1", @default_ttl_ms, tags: ["tag1"])
      Cache.Cachex.put("key2", "value2", @default_ttl_ms, tags: ["tag2"])
      Cache.Cachex.put("key3", "value3", @default_ttl_ms, tags: ["tag3"])

      assert Cache.Cachex.invalidate_tags(["tag1", "tag2"]) == :ok

      assert Cache.Cachex.get("key1") == :miss
      assert Cache.Cachex.get("key2") == :miss
      assert Cache.Cachex.get("key3") == {:ok, "value3"}
    end

    test "returns :ok even when tags don't exist" do
      assert Cache.Cachex.invalidate_tags(["nonexistent_tag"]) == :ok
    end

    test "handles empty tag list" do
      Cache.Cachex.put("key", "value", @default_ttl_ms, [])
      assert Cache.Cachex.invalidate_tags([]) == :ok
      assert Cache.Cachex.get("key") == {:ok, "value"}
    end
  end

  describe "data encoding/decoding" do
    test "handles various Elixir data types correctly" do
      test_cases = [
        {"string", "hello world"},
        {"integer", 42},
        {"float", 3.14159},
        {"atom", :test_atom},
        {"list", [1, 2, 3, :a, :b]},
        {"tuple", {:ok, "result", 123}},
        {"map", %{key: "value", nested: %{inner: true}}},
        {"keyword_list", [name: "test", age: 25]},
        {"binary", <<1, 2, 3, 4, 5>>}
      ]

      for {name, value} <- test_cases do
        Cache.Cachex.put(name, value, @default_ttl_ms, [])
        assert Cache.Cachex.get(name) == {:ok, value}, "Failed for #{name}"
      end
    end

    test "handles large data structures" do
      large_list = Enum.to_list(1..1000)
      Cache.Cachex.put("large_list", large_list, @default_ttl_ms, [])
      assert Cache.Cachex.get("large_list") == {:ok, large_list}
    end

    test "handles unicode strings" do
      unicode_string = "Hello 世界 🌍 Ελληνικά"
      Cache.Cachex.put("unicode", unicode_string, @default_ttl_ms, [])
      assert Cache.Cachex.get("unicode") == {:ok, unicode_string}
    end
  end
end
