# Deployment

This guide covers what changes when Lotus runs on more than one node. A single node needs none of it: everything below is about state that lives on each node and how a change on one node reaches the others.

Lotus does not connect nodes. Use distributed Erlang the way you already do, with `libcluster`, DNS or a static list. Once nodes are connected, everything in this guide works without further configuration.

## What is shared, what is per node

| State | Where it lives | In a cluster |
|---|---|---|
| Saved queries, dashboards, variables | the storage repo | shared through the database |
| Configuration (`config :lotus`) | application env on each node | every node must ship the same config |
| Compiled middleware and static visibility rules | each node, built from config at boot | identical as long as config is |
| Query and discovery results (`Lotus.Cache`) | per node with `Lotus.Cache.ETS`; spread over nodes with `Lotus.Cache.Cachex` and a router | invalidations are relayed, values are not |
| Schema metadata (`Lotus.Storage.SchemaCache`) | `Lotus.Cache`, per node, with a TTL | same as the cache above |
| Processes a source adapter owns (pools, channels) | per node under `Lotus.Source.Supervisor` | `Lotus.Source.reconcile/0` relays a reconcile |
| Sources added at runtime | wherever your `Lotus.Source.Resolver` keeps them | the static resolver keeps them in memory on one node; a cluster needs a database-backed resolver |
| Suspended sources | per node | not relayed; idleness is a per-node fact |

Cache keys carry the Lotus version. During a rolling deploy that mixes two versions, each version fills and reads its own entries, so a result cached by the old version is never served by the new one.

## How a change reaches the other nodes

`Lotus.Notifier` relays notifications between nodes over OTP process groups, the `:pg` module of the `kernel` application. It starts as the first child of `Lotus.Supervisor` and needs no configuration: connected nodes share it automatically. Core uses two topics:

| Topic | Payload | Sent by | Applied by |
|---|---|---|---|
| `:cache` | `{:invalidate_tags, tags}`, `{:delete, key}` | `Lotus.Cache.invalidate_tags/1`, `Lotus.Cache.delete/1` on a node-local adapter | `Lotus.Cache.Relay` on every other node |
| `:sources` | `:reconcile`, `{:invalidate, name}` | `Lotus.Source.reconcile/0`, `Lotus.Source.invalidate/1` | the source reconciler on every other node |

The node that makes the change applies it locally first and returns, then the others hear about it. Delivery is a message send between connected nodes: a node that is partitioned away misses it and relies on cache TTLs and its next reconcile. A call made before `Lotus.Supervisor` is up, from a start phase or a release task, applies to that node alone.

Your own per-node state uses the same relay. A store that caches visibility rules or settings on each node listens on a topic of its own, and the code path that writes the rules notifies it after the write:

```elixir
# in the store's init/1
Lotus.Notifier.listen({MyApp, :visibility})

# in the store's handle_info/2
def handle_info({:lotus_notification, {MyApp, :visibility}, {:changed, source}}, state) do
  {:noreply, reload(state, source)}
end

# after the admin action writes the rules on this node
Lotus.Notifier.notify({MyApp, :visibility}, {:changed, source}, except: [node()])
```

Prefix your topics with your application name so they cannot clash with core's.

## Cache adapters in a cluster

`c:Lotus.Cache.Adapter.scope/1` tells `Lotus.Cache` how far one `delete/1` or one `invalidate_tags/1` on the adapter reaches, separately. `:node` means the call only touches the calling node, so it is relayed over `Lotus.Notifier`. `:cluster` means one call already reaches every node and nothing is relayed. `Lotus.Cache.scope/1` returns the answer for the configured adapter.

### `Lotus.Cache.ETS`

Each node keeps its own entries. Two nodes that run the same query each fill their own copy, so the hit rate is per node. A tag invalidation or a schema cache invalidation on one node drops the matching entries on every node.

### `Lotus.Cache.Cachex`

Without `cachex_opts`, the value cache uses `Cachex.Router.Ring` with `monitor: true`: entries are spread over the connected nodes by key, nodes that join or leave are picked up, and one node's result serves the whole cluster. Any `cachex_opts` you pass replace that default, so add the router back when you set other options:

```elixir
config :lotus,
  cache: %{
    adapter: Lotus.Cache.Cachex,
    cachex_opts: [
      limit: 1_000_000,
      router: Cachex.Spec.router(module: Cachex.Router.Ring, options: [monitor: true])
    ]
  }
```

Tag bookkeeping stays on the node that wrote the entry, because Cachex routes one key per call and a transaction over keys that live on different nodes fails. `invalidate_tags/1` deletes each key with its own routed call, and the invalidation is relayed so each node drops the keys it tagged. A single-key `delete/1` is already routed to the owner, so it is not relayed. A node that restarts loses its bookkeeping; the entries it tagged then expire on their TTL instead of on the next invalidation.

Remember that `cachex_opts` must be set in `config/runtime.exs`: Cachex records are not available at compile time.

### A shared store

An adapter over Redis or another shared store returns `:cluster` from `scope/1` for both operations, and Lotus relays nothing. See `Lotus.Cache.Adapter` for the reach of each callback.

## Sources in a cluster

`Lotus.Source.reconcile/0` reconciles the node it runs on and returns that node's report, then tells the other nodes to reconcile. Each of them reads the resolver on its own, so the resolver must return the same sources everywhere: a database-backed resolver does, the static resolver does only for sources in config.

Call `Lotus.Source.invalidate/1` and then `Lotus.Source.reconcile/0` after a source is added, edited or removed at runtime, on whichever node handled the change. The other nodes drop their cached adapter and restart the source's processes.

`Lotus.Source.Supervisor.suspend/1` and `resume/1` are not relayed. An idle policy that stops a source nobody has used for an hour is deciding for one node.

## What Lotus does not do

- It does not elect a leader or run anything once per cluster. A host that schedules work runs it on one node by its own means.
- It does not replicate cache values. A node that misses fills its own entry.
- It does not connect nodes or watch membership.

## See also

- [Caching](caching.md) for profiles, tags and scope invalidation
- [Custom Resolvers](custom-resolvers.md) for database-backed sources and visibility rules
- [Source Adapters](source-adapters.md) for the processes an adapter owns per source
