defmodule Lotus.CacheTest do
  use Lotus.CacheCase
  use Mimic

  alias Lotus.Cache
  alias Lotus.Config

  describe "when cache is enabled" do
    setup :verify_on_exit!

    setup do
      Config
      |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
      |> stub(:cache_namespace, fn -> "test_app" end)

      :ok
    end

    test "enabled?/0 returns true when adapter is configured" do
      assert Cache.enabled?()
    end

    test "get/1 returns cached values" do
      Cache.put("test_key", "test_value", 5000)
      assert Cache.get("test_key") == {:ok, "test_value"}
    end

    test "get/1 returns :miss for non-existent keys" do
      assert Cache.get("nonexistent") == :miss
    end

    test "put/4 stores values with default options" do
      assert Cache.put("key1", "value1", 5000) == :ok
      assert Cache.get("key1") == {:ok, "value1"}
    end

    test "put/4 stores values with custom options" do
      assert Cache.put("key2", "value2", 5000, compress: false) == :ok
      assert Cache.get("key2") == {:ok, "value2"}
    end

    test "put/3 works without options" do
      assert Cache.put("key3", "value3", 5000) == :ok
      assert Cache.get("key3") == {:ok, "value3"}
    end

    test "delete/1 removes cached values" do
      Cache.put("delete_me", "value", 5000)
      assert Cache.get("delete_me") == {:ok, "value"}

      assert Cache.delete("delete_me") == :ok
      assert Cache.get("delete_me") == :miss
    end

    test "get_or_store/4 returns cached value when exists" do
      Cache.put("existing", "cached_value", 5000)

      result = Cache.get_or_store("existing", 5000, fn -> "computed_value" end)
      assert result == {:ok, "cached_value", :hit}
    end

    test "get_or_store/4 computes and caches value when missing" do
      result = Cache.get_or_store("missing", 5000, fn -> "computed_value" end)
      assert result == {:ok, "computed_value", :miss}
      assert Cache.get("missing") == {:ok, "computed_value"}
    end

    test "get_or_store/3 works without options" do
      result = Cache.get_or_store("no_opts", 5000, fn -> "value" end)
      assert result == {:ok, "value", :miss}
    end

    test "invalidate_tags/1 removes tagged entries" do
      Cache.put("tag1_key", "value1", 5000, tags: ["tag1"])
      Cache.put("tag2_key", "value2", 5000, tags: ["tag2"])

      assert Cache.invalidate_tags(["tag1"]) == :ok

      assert Cache.get("tag1_key") == :miss
      assert Cache.get("tag2_key") == {:ok, "value2"}
    end

    test "invalidate_tags/1 handles empty list" do
      Cache.put("untagged", "value", 5000)
      assert Cache.invalidate_tags([]) == :ok
      assert Cache.get("untagged") == {:ok, "value"}
    end

    test "uses configured namespace to avoid conflicts" do
      Cache.put("namespaced_key", "value1", 5000)
      assert Cache.get("namespaced_key") == {:ok, "value1"}

      Config
      |> stub(:cache_namespace, fn -> "different_namespace" end)

      assert Cache.get("namespaced_key") == :miss

      Config
      |> stub(:cache_namespace, fn -> "test_app" end)

      assert Cache.get("namespaced_key") == {:ok, "value1"}
    end
  end

  describe "when cache is disabled" do
    setup :verify_on_exit!

    setup do
      Config
      |> stub(:cache_adapter, fn -> :error end)
      |> stub(:cache_namespace, fn -> "test_app" end)

      :ok
    end

    test "enabled?/0 returns false when no adapter configured" do
      refute Cache.enabled?()
    end

    test "get/1 returns :miss when cache disabled" do
      assert Cache.get("any_key") == :miss
    end

    test "put/4 returns :ok but does nothing when cache disabled" do
      assert Cache.put("key", "value", 5000) == :ok
      assert Cache.get("key") == :miss
    end

    test "put/3 returns :ok when cache disabled" do
      assert Cache.put("key", "value", 5000) == :ok
    end

    test "delete/1 returns :ok when cache disabled" do
      assert Cache.delete("any_key") == :ok
    end

    test "get_or_store/4 always computes value when cache disabled" do
      call_count = :counters.new(1, [])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        "computed_value"
      end

      result1 = Cache.get_or_store("key", 5000, fun)
      result2 = Cache.get_or_store("key", 5000, fun)

      assert result1 == {:ok, "computed_value", :miss}
      assert result2 == {:ok, "computed_value", :miss}
      assert :counters.get(call_count, 1) == 2
    end

    test "get_or_store/3 works without options when cache disabled" do
      result = Cache.get_or_store("key", 5000, fn -> "value" end)
      assert result == {:ok, "value", :miss}
    end

    test "invalidate_tags/1 returns :ok when cache disabled" do
      assert Cache.invalidate_tags(["tag1", "tag2"]) == :ok
    end
  end

  describe "adapter without invalidate_tags support" do
    defmodule MockAdapter do
      @behaviour Lotus.Cache.Adapter

      def spec_config, do: []
      def get(_key), do: :miss
      def put(_key, _value, _ttl, _opts), do: :ok
      def delete(_key), do: :ok
      def get_or_store(_key, _ttl, fun, _opts), do: {:ok, fun.(), :miss}
      def touch(_key, _ttl), do: :ok
      def invalidate_tags(_tags), do: :ok
    end

    setup :verify_on_exit!

    setup do
      Config
      |> stub(:cache_adapter, fn -> {:ok, MockAdapter} end)
      |> stub(:cache_namespace, fn -> "test" end)

      :ok
    end

    test "invalidate_tags/1 returns :ok when adapter doesn't support tags" do
      assert Cache.invalidate_tags(["tag1"]) == :ok
    end
  end

  describe "configuration edge cases" do
    setup :verify_on_exit!

    test "handles nil namespace gracefully" do
      Config
      |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
      |> stub(:cache_namespace, fn -> nil end)

      # Should not crash with nil namespace
      assert Cache.put("key", "value", 5000) == :ok
    end
  end
end
