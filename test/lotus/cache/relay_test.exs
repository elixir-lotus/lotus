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
    def scope(_operation), do: :cluster
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

  defmodule BlockingAdapter do
    use Lotus.Cache.Adapter

    def register(pid), do: :persistent_term.put({__MODULE__, :parent}, pid)

    def spec_config, do: []
    def get(_key), do: :miss
    def put(_key, _value, _ttl_ms, _opts), do: :ok
    def get_or_store(_key, _ttl_ms, fun, _opts), do: {:ok, fun.(), :miss}
    def invalidate_tags(_tags), do: :ok
    def touch(_key, _ttl_ms), do: :ok

    def delete(_key) do
      send(:persistent_term.get({__MODULE__, :parent}), {:blocked_in, self()})

      receive do
        :release -> :ok
      end
    end
  end

  setup :set_mimic_global

  setup do
    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> "relay_test" end)

    :ok
  end

  describe "scope/1" do
    test "is :node for both operations on the ETS adapter" do
      assert Cache.scope(:delete) == :node
      assert Cache.scope(:invalidate_tags) == :node
    end

    test "is what the adapter declares" do
      stub(Config, :cache_adapter, fn -> {:ok, ClusterAdapter} end)
      assert Cache.scope(:delete) == :cluster
      assert Cache.scope(:invalidate_tags) == :cluster
    end

    test "is :node for an adapter that does not declare it" do
      stub(Config, :cache_adapter, fn -> {:ok, BareAdapter} end)
      assert Cache.scope(:delete) == :node
      assert Cache.scope(:invalidate_tags) == :node
    end

    test "is :cluster with no adapter configured" do
      stub(Config, :cache_adapter, fn -> :error end)
      assert Cache.scope(:delete) == :cluster
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

      wait_until(fn -> Cache.get("tagged") == :miss end)
      assert Cache.get("other") == {:ok, "value"}
    end

    test "drops one namespaced key" do
      :ok = Cache.put("one", "value", 60_000)
      :ok = Cache.put("two", "value", 60_000)

      send(Relay, {:lotus_notification, :cache, {:delete, "relay_test:one"}})

      wait_until(fn -> Cache.get("one") == :miss end)
      assert Cache.get("two") == {:ok, "value"}
    end

    test "applies each notification in its own task, off the relay's mailbox" do
      %{task_supervisor: supervisor} = :sys.get_state(Relay)
      parent = self()

      stub(Config, :cache_adapter, fn -> {:ok, BlockingAdapter} end)
      BlockingAdapter.register(parent)

      send(Relay, {:lotus_notification, :cache, {:delete, "relay_test:slow"}})
      assert_receive {:blocked_in, blocked_pid}

      refute blocked_pid == Process.whereis(Relay)
      assert blocked_pid in Task.Supervisor.children(supervisor)
      assert :sys.get_state(Relay).task_supervisor == supervisor

      send(blocked_pid, :release)
    end

    test "ignores an unknown payload" do
      send(Relay, {:lotus_notification, :cache, :something_else})
      send(Relay, :unrelated)

      assert %{task_supervisor: _} = :sys.get_state(Relay)
      assert Process.alive?(Process.whereis(Relay))
    end

    test "is a no-op with no adapter configured" do
      stub(Config, :cache_adapter, fn -> :error end)

      assert Cache.apply_relayed({:invalidate_tags, ["tag:x"]}) == :ok
      assert Cache.apply_relayed({:delete, "relay_test:x"}) == :ok
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition did not become true in time")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
