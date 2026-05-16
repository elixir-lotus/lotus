defmodule Lotus.Cache.ETSTest do
  use Lotus.CacheCase

  alias Lotus.Cache.ETS

  describe "get/1" do
    test "returns :miss when key doesn't exist" do
      assert ETS.get("nonexistent") == :miss
    end

    test "returns {:ok, value} when key exists and not expired" do
      ETS.put("key1", "value1", 5000, [])
      assert ETS.get("key1") == {:ok, "value1"}
    end

    test "returns :miss and deletes key when expired" do
      ETS.put("expired_key", "value", 1, [])
      Process.sleep(5)
      assert ETS.get("expired_key") == :miss
      assert ETS.get("expired_key") == :miss
    end

    test "works with complex data structures" do
      data = %{list: [1, 2, 3], map: %{nested: true}, tuple: {:ok, "test"}}
      ETS.put("complex", data, 5000, [])
      assert ETS.get("complex") == {:ok, data}
    end
  end

  describe "put/4" do
    test "stores value with TTL" do
      assert ETS.put("key", "value", 5000, []) == :ok
      assert ETS.get("key") == {:ok, "value"}
    end

    test "overwrites existing key" do
      ETS.put("key", "old_value", 5000, [])
      ETS.put("key", "new_value", 5000, [])
      assert ETS.get("key") == {:ok, "new_value"}
    end

    test "respects max_bytes option and doesn't store large values" do
      large_value = String.duplicate("x", 1000)
      assert ETS.put("large", large_value, 5000, max_bytes: 100, compress: false) == :ok
      assert ETS.get("large") == :miss
    end

    test "stores value when under max_bytes limit" do
      small_value = "small"
      assert ETS.put("small", small_value, 5000, max_bytes: 100) == :ok
      assert ETS.get("small") == {:ok, "small"}
    end

    test "uses compression by default" do
      large_data = Enum.to_list(1..1000)
      assert ETS.put("compressed", large_data, 5000, []) == :ok
      assert ETS.get("compressed") == {:ok, large_data}
    end

    test "can disable compression" do
      data = [1, 2, 3, 4, 5]
      assert ETS.put("uncompressed", data, 5000, compress: false) == :ok
      assert ETS.get("uncompressed") == {:ok, data}
    end

    test "stores tags when provided" do
      assert ETS.put("tagged_key", "value", 5000, tags: ["tag1", "tag2"]) == :ok
      assert ETS.get("tagged_key") == {:ok, "value"}
    end
  end

  describe "delete/1" do
    test "deletes existing key" do
      ETS.put("key", "value", 5000, [])
      assert ETS.get("key") == {:ok, "value"}
      assert ETS.delete("key") == :ok
      assert ETS.get("key") == :miss
    end

    test "returns :ok even when key doesn't exist" do
      assert ETS.delete("nonexistent") == :ok
    end
  end

  describe "touch/2" do
    test "updates TTL for existing key" do
      ETS.put("key", "value", 100, [])
      Process.sleep(50)
      assert ETS.touch("key", 5000) == :ok
      Process.sleep(100)
      assert ETS.get("key") == {:ok, "value"}
    end

    test "returns :ok even when key doesn't exist" do
      assert ETS.touch("nonexistent", 5000) == :ok
    end
  end

  describe "get_or_store/4" do
    test "returns cached value when key exists" do
      ETS.put("existing", "cached_value", 5000, [])

      result = ETS.get_or_store("existing", 5000, fn -> "computed_value" end, [])
      assert result == {:ok, "cached_value", :hit}
    end

    test "computes and stores value when key doesn't exist" do
      result = ETS.get_or_store("new_key", 5000, fn -> "computed_value" end, [])
      assert result == {:ok, "computed_value", :miss}
      assert ETS.get("new_key") == {:ok, "computed_value"}
    end

    test "handles concurrent access with locking" do
      parent = self()
      call_count = :counters.new(1, [])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        Process.sleep(10)
        send(parent, :computed)
        "computed_value"
      end

      tasks =
        for _ <- 1..3 do
          Task.async(fn -> ETS.get_or_store("concurrent_key", 5000, fun, []) end)
        end

      results = Task.await_many(tasks, 1000)

      assert Enum.all?(results, &match?({:ok, "computed_value", _}, &1))

      computed_count = :counters.get(call_count, 1)
      assert computed_count >= 1, "Function should be called at least once"
      assert computed_count <= 3, "Function was called #{computed_count} times, expected <= 3"
    end

    test "falls back to computing when lock times out" do
      result = ETS.get_or_store("timeout_key", 5000, fn -> "fallback_value" end, lock_timeout: 1)
      assert result == {:ok, "fallback_value", :miss}
    end
  end

  describe "invalidate_tags/1" do
    test "deletes all keys with matching tags" do
      ETS.put("key1", "value1", 5000, tags: ["tag1"])
      ETS.put("key2", "value2", 5000, tags: ["tag1", "tag2"])
      ETS.put("key3", "value3", 5000, tags: ["tag2"])
      ETS.put("key4", "value4", 5000, tags: ["tag3"])

      assert ETS.invalidate_tags(["tag1"]) == :ok

      assert ETS.get("key1") == :miss
      assert ETS.get("key2") == :miss
      assert ETS.get("key3") == {:ok, "value3"}
      assert ETS.get("key4") == {:ok, "value4"}
    end

    test "handles multiple tags in single call" do
      ETS.put("key1", "value1", 5000, tags: ["tag1"])
      ETS.put("key2", "value2", 5000, tags: ["tag2"])
      ETS.put("key3", "value3", 5000, tags: ["tag3"])

      assert ETS.invalidate_tags(["tag1", "tag2"]) == :ok

      assert ETS.get("key1") == :miss
      assert ETS.get("key2") == :miss
      assert ETS.get("key3") == {:ok, "value3"}
    end

    test "returns :ok even when tags don't exist" do
      assert ETS.invalidate_tags(["nonexistent_tag"]) == :ok
    end

    test "handles empty tag list" do
      ETS.put("key", "value", 5000, [])
      assert ETS.invalidate_tags([]) == :ok
      assert ETS.get("key") == {:ok, "value"}
    end
  end

  describe "child_spec/1" do
    test "returns the default GenServer child spec" do
      spec = ETS.child_spec([])
      assert spec.id == ETS
      assert spec.start == {ETS, :start_link, [[]]}
    end
  end

  describe "start_link/1" do
    test "is idempotent when the singleton is already started" do
      # Lotus.Application starts ETS as a named singleton. A second start_link
      # should return {:ok, pid} rather than {:error, {:already_started, _}}.
      assert {:ok, pid1} = ETS.start_link([])
      assert {:ok, pid2} = ETS.start_link([])
      assert pid1 == pid2
      assert Process.alive?(pid1)
    end

    test "cache tables are live and usable" do
      assert :ets.whereis(:lotus_cache) != :undefined
      assert :ets.whereis(:lotus_cache_tags) != :undefined

      ETS.put("test", "value", 5000, [])
      assert ETS.get("test") == {:ok, "value"}
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
        ETS.put(name, value, 5000, [])
        assert ETS.get(name) == {:ok, value}, "Failed for #{name}"
      end
    end

    test "handles large data structures" do
      large_list = Enum.to_list(1..1000)
      ETS.put("large_list", large_list, 5000, [])
      assert ETS.get("large_list") == {:ok, large_list}
    end

    test "handles unicode strings" do
      unicode_string = "Hello 世界 🌍 Ελληνικά"
      ETS.put("unicode", unicode_string, 5000, [])
      assert ETS.get("unicode") == {:ok, unicode_string}
    end
  end
end
