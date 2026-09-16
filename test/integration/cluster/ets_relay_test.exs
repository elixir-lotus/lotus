defmodule Lotus.Integration.Cluster.ETSRelayTest do
  # Two nodes, both on Lotus.Cache.ETS: an invalidation on one node must
  # drop the matching entries on the other. Run with `mix test --only cluster`
  # after `epmd -daemon`.
  use ExUnit.Case, async: false
  use Mimic

  alias Lotus.Cache
  alias Lotus.Cache.ETS
  alias Lotus.Cache.KeyBuilder
  alias Lotus.Config
  alias Lotus.Test.Peer

  @moduletag :cluster
  @namespace "cluster_ets"
  @ttl 60_000

  setup_all do
    {pid, peer} =
      Peer.start!(:lotus_peer_ets, cache: %{adapter: ETS, namespace: @namespace})

    on_exit(fn -> Peer.stop(pid) end)
    %{peer: peer}
  end

  setup :set_mimic_global

  setup %{peer: peer} do
    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> @namespace end)

    for table <- [:lotus_cache, :lotus_cache_tags] do
      :ets.delete_all_objects(table)
      Peer.call(peer, :ets, :delete_all_objects, [table])
    end

    :ok
  end

  test "both nodes see each other's relay", %{peer: peer} do
    listeners = Lotus.Notifier.listeners(:cache)

    assert Process.whereis(Lotus.Cache.Relay) in listeners
    assert Peer.call(peer, Process, :whereis, [Lotus.Cache.Relay]) in listeners
  end

  test "a tag invalidation on this node drops the peer's tagged entries", %{peer: peer} do
    :ok = Cache.put("local", "value", @ttl, tags: ["tag:shared"])
    :ok = Peer.call(peer, Cache, :put, ["remote", "value", @ttl, [tags: ["tag:shared"]]])
    :ok = Peer.call(peer, Cache, :put, ["untouched", "value", @ttl, [tags: ["tag:other"]]])

    assert Cache.invalidate_tags(["tag:shared"]) == :ok

    assert Cache.get("local") == :miss
    Peer.wait_until(fn -> Peer.call(peer, Cache, :get, ["remote"]) == :miss end)
    assert Peer.call(peer, Cache, :get, ["untouched"]) == {:ok, "value"}
  end

  test "a tag invalidation on the peer drops this node's tagged entries", %{peer: peer} do
    :ok = Cache.put("local", "value", @ttl, tags: ["tag:shared"])
    :ok = Cache.put("untouched", "value", @ttl, tags: ["tag:other"])

    assert Peer.call(peer, Cache, :invalidate_tags, [["tag:shared"]]) == :ok

    Peer.wait_until(fn -> Cache.get("local") == :miss end)
    assert Cache.get("untouched") == {:ok, "value"}
  end

  test "a delete on this node drops the peer's entry", %{peer: peer} do
    :ok = Peer.call(peer, Cache, :put, ["one", "value", @ttl, []])
    :ok = Peer.call(peer, Cache, :put, ["two", "value", @ttl, []])

    assert Cache.delete("one") == :ok

    Peer.wait_until(fn -> Peer.call(peer, Cache, :get, ["one"]) == :miss end)
    assert Peer.call(peer, Cache, :get, ["two"]) == {:ok, "value"}
  end

  test "a scope invalidation on this node reaches the peer", %{peer: peer} do
    scope = %{tenant_id: 42}
    options = Cache.build_options([], ["scope:#{KeyBuilder.scope_digest(scope)}"])
    :ok = Peer.call(peer, Cache, :put, ["tenant", "value", @ttl, options])

    assert Cache.invalidate_scope(scope) == :ok

    Peer.wait_until(fn -> Peer.call(peer, Cache, :get, ["tenant"]) == :miss end)
  end

  test "source notifications cross nodes", %{peer: peer} do
    :ok = Lotus.Notifier.listen(:sources)
    on_exit(fn -> Lotus.Notifier.unlisten(:sources) end)

    {:ok, _report} = Peer.call(peer, Lotus.Source, :reconcile, [])
    :ok = Peer.call(peer, Lotus.Source, :invalidate, ["warehouse"])

    assert_receive {:lotus_notification, :sources, :reconcile}, 2_000
    assert_receive {:lotus_notification, :sources, {:invalidate, "warehouse"}}, 2_000
  end
end
