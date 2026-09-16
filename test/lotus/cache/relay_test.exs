defmodule Lotus.Cache.RelayTest do
  use Lotus.CacheCase, async: false
  use Mimic

  alias Lotus.Cache
  alias Lotus.Cache.ETS
  alias Lotus.Cache.Relay
  alias Lotus.Config
  alias Lotus.Notifier

  defmodule ClusterAdapter do
    use Lotus.Cache.Adapter

    def spec_config, do: []
    def scope, do: :cluster
    def get(_key), do: :miss
    def put(_key, _value, _ttl_ms, _opts), do: :ok
    def delete(_key), do: :ok
    def get_or_store(_key, _ttl_ms, fun, _opts), do: {:ok, fun.(), :miss}
    def invalidate_tags(_tags), do: :ok
    def touch(_key, _ttl_ms), do: :ok
  end

  defmodule BareAdapter do
    use Lotus.Cache.Adapter

    def spec_config, do: []
    def get(_key), do: :miss
    def put(_key, _value, _ttl_ms, _opts), do: :ok
    def delete(_key), do: :ok
    def get_or_store(_key, _ttl_ms, fun, _opts), do: {:ok, fun.(), :miss}
    def invalidate_tags(_tags), do: :ok
    def touch(_key, _ttl_ms), do: :ok
  end

  setup :set_mimic_global

  setup do
    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> "relay_test" end)

    :ok
  end

  describe "scope/0" do
    test "is :node for the ETS adapter" do
      assert Cache.scope() == :node
    end

    test "is what the adapter declares" do
      stub(Config, :cache_adapter, fn -> {:ok, ClusterAdapter} end)
      assert Cache.scope() == :cluster
    end

    test "is :node for an adapter that does not declare it" do
      stub(Config, :cache_adapter, fn -> {:ok, BareAdapter} end)
      assert Cache.scope() == :node
    end

    test "is :cluster with no adapter configured" do
      stub(Config, :cache_adapter, fn -> :error end)
      assert Cache.scope() == :cluster
    end
  end

  describe "notifying from the facade" do
    setup do
      :ok = Notifier.listen(:cache)
      on_exit(fn -> Notifier.unlisten(:cache) end)
      :ok
    end

    test "invalidate_tags/1 applies locally and does not notify this node's listeners" do
      :ok = Cache.put("tagged", "value", 60_000, tags: ["tag:a"])

      assert Cache.invalidate_tags(["tag:a"]) == :ok

      assert Cache.get("tagged") == :miss
      refute_receive {:lotus_notification, :cache, {:invalidate_tags, ["tag:a"]}}
    end

    test "delete/1 applies locally and does not notify this node's listeners" do
      :ok = Cache.put("one", "value", 60_000)

      assert Cache.delete("one") == :ok

      assert Cache.get("one") == :miss
      refute_receive {:lotus_notification, :cache, {:delete, _}}
    end
  end

  describe "applying a relayed invalidation" do
    test "the relay listens on the :cache topic" do
      assert Process.whereis(Relay) in Notifier.listeners(:cache)
    end

    test "drops the tagged entries of this node" do
      :ok = Cache.put("tagged", "value", 60_000, tags: ["tag:remote"])
      :ok = Cache.put("other", "value", 60_000, tags: ["tag:other"])

      send(Relay, {:lotus_notification, :cache, {:invalidate_tags, ["tag:remote"]}})
      :sys.get_state(Relay)

      assert Cache.get("tagged") == :miss
      assert Cache.get("other") == {:ok, "value"}
    end

    test "drops one namespaced key" do
      :ok = Cache.put("one", "value", 60_000)
      :ok = Cache.put("two", "value", 60_000)

      send(Relay, {:lotus_notification, :cache, {:delete, "relay_test:one"}})
      :sys.get_state(Relay)

      assert Cache.get("one") == :miss
      assert Cache.get("two") == {:ok, "value"}
    end

    test "ignores an unknown payload" do
      send(Relay, {:lotus_notification, :cache, :something_else})
      send(Relay, :unrelated)

      assert :sys.get_state(Relay) == %{}
      assert Process.alive?(Process.whereis(Relay))
    end

    test "is a no-op with no adapter configured" do
      stub(Config, :cache_adapter, fn -> :error end)

      assert Cache.apply_relayed({:invalidate_tags, ["tag:x"]}) == :ok
      assert Cache.apply_relayed({:delete, "relay_test:x"}) == :ok
    end
  end
end
