defmodule Lotus.Integration.Cluster.CachexRingTest do
  # Two nodes on Lotus.Cache.Cachex with Cachex.Router.Ring: entries are
  # spread over both nodes by key, tagged writes and tag invalidations must
  # work across them. Run with `mix test --only cluster` after `epmd -daemon`.
  use ExUnit.Case, async: false
  use Mimic

  import Cachex.Spec

  alias Lotus.Cache
  alias Lotus.Config
  alias Lotus.Test.Peer

  @moduletag :cluster
  @namespace "cluster_cachex"
  @ttl 60_000
  @cache_config %{
    adapter: Cache.Cachex,
    namespace: @namespace,
    cachex_opts: [router: router(module: Cachex.Router.Ring, options: [monitor: true])]
  }

  setup_all do
    Config
    |> stub(:cache_adapter, fn -> {:ok, Cache.Cachex} end)
    |> stub(:cache_namespace, fn -> @namespace end)
    |> stub(:cache_config, fn -> @cache_config end)

    # Connect the peer before either Cachex starts, so both rings see both
    # nodes from the start.
    Peer.ensure_distribution!()
    {pid, peer} = Peer.start!(:lotus_peer_cachex, cache: @cache_config)

    :ok = Supervisor.terminate_child(Lotus.Supervisor, Lotus.Cache.ETS)

    on_exit(fn ->
      Peer.stop(pid)
      {:ok, _pid} = Supervisor.restart_child(Lotus.Supervisor, Lotus.Cache.ETS)
    end)

    for spec <- Cache.Cachex.spec_config() do
      start_link_supervised!(spec)
    end

    %{peer: peer}
  end

  setup :set_mimic_global

  setup %{peer: peer} do
    Config
    |> stub(:cache_adapter, fn -> {:ok, Cache.Cachex} end)
    |> stub(:cache_namespace, fn -> @namespace end)
    |> stub(:cache_config, fn -> @cache_config end)

    Cachex.clear(:lotus_cache)
    Cachex.clear(:lotus_cache_tags)
    Peer.call(peer, Cachex, :clear, [:lotus_cache_tags])
    :ok
  end

  defp keys(prefix), do: for(n <- 1..40, do: "#{prefix}-#{n}")

  defp owned_locally?(key), do: :ets.member(:lotus_cache, "#{@namespace}:#{key}")

  test "the ring spreads entries over both nodes", %{peer: peer} do
    for key <- keys("spread"), do: :ok = Cache.put(key, "value", @ttl)

    assert Peer.call(peer, Node, :list, []) == [node()]
    local = Enum.count(keys("spread"), &owned_locally?/1)
    assert local > 0 and local < 40

    for key <- keys("spread") do
      assert Cache.get(key) == {:ok, "value"}
      assert Peer.call(peer, Cache, :get, [key]) == {:ok, "value"}
    end
  end

  test "a tagged write and a tag invalidation reach entries owned by the peer" do
    for key <- keys("tagged"), do: :ok = Cache.put(key, "value", @ttl, tags: ["tag:ring"])
    :ok = Cache.put("other", "value", @ttl, tags: ["tag:other"])

    assert Cache.invalidate_tags(["tag:ring"]) == :ok

    for key <- keys("tagged"), do: assert(Cache.get(key) == :miss)
    assert Cache.get("other") == {:ok, "value"}
  end

  test "an invalidation on this node drops the keys the peer tagged", %{peer: peer} do
    for key <- keys("peer") do
      :ok = Peer.call(peer, Cache, :put, [key, "value", @ttl, [tags: ["tag:ring"]]])
    end

    assert Cache.invalidate_tags(["tag:ring"]) == :ok

    Peer.wait_until(fn -> Enum.all?(keys("peer"), &(Cache.get(&1) == :miss)) end)
  end

  test "get_or_store/4 runs the fetch on the caller and the value is visible everywhere",
       %{peer: peer} do
    parent = self()

    assert {:ok, "computed", :miss} =
             Cache.get_or_store("lazy", @ttl, fn ->
               send(parent, {:fetched_on, node()})
               "computed"
             end)

    assert_receive {:fetched_on, local} when local == node()
    assert Peer.call(peer, Cache, :get, ["lazy"]) == {:ok, "computed"}
  end
end
