if Code.ensure_loaded?(Cachex) do
  defmodule Lotus.Cache.Cachex do
    @moduledoc """
    A Cachex-based, local or distributed, in-memory cache adapter for Lotus.

    This adapter requires the `Cachex` library. Please add `{:cachex, "~> 4.0"}` to your dependencies.

    Example configuration in `config/runtime.exs`:

        config :lotus, :cache,
          adapter: Lotus.Cache.Cachex,
          cachex_opts: [limit: 1_000_000] # Optional Cachex options

    See [Cachex documentation](https://hexdocs.pm/cachex/) for available options.

    ## Routing

    Without `cachex_opts`, the value cache starts with
    `Cachex.Router.Ring` and `monitor: true`: entries are spread over the
    connected nodes by key, nodes that join or leave are picked up, and one
    node's result serves the whole cluster. Any `cachex_opts` you pass
    replace that default entirely, so a host that sets `limit:` alone gets
    Cachex's own default, `Cachex.Router.Local`. Add the router back to keep
    distributed mode:

        cachex_opts: [
          limit: 1_000_000,
          router: Cachex.Spec.router(module: Cachex.Router.Ring, options: [monitor: true])
        ]

    Choose a router by [following the Cachex docs](https://hexdocs.pm/cachex/cache-routers.html#default-routers).

    ## Tags and invalidation in a cluster

    Cachex routes one key per call and rejects a transaction whose keys live
    on different nodes, and a function passed to a routed call runs on the
    node that owns the key. This adapter therefore keeps its tag bookkeeping
    on the node that wrote the entry, in a second cache that always uses
    `Cachex.Router.Local`, and `invalidate_tags/1` deletes each key with its
    own routed call. Because that bookkeeping is per node, `scope/0`
    returns `:node` and `Lotus.Cache` relays every `delete/1` and
    `invalidate_tags/1` to the other nodes over `Lotus.Notifier`, where each
    node drops the keys it tagged. `get_or_store/4` runs the fetch function
    on the caller's node and writes the result with a routed `put/4`.
    """

    use Lotus.Cache.Adapter

    import Cachex.Spec

    alias Lotus.Config

    @cache_name :lotus_cache
    @tag_cache_name :lotus_cache_tags

    @impl Lotus.Cache.Adapter
    def spec_config do
      value_opts = value_cache_opts()
      tag_opts = Keyword.put(value_opts, :router, router(module: Cachex.Router.Local))

      [
        Supervisor.child_spec({Cachex, [name: @cache_name] ++ value_opts},
          id: {Cachex, @cache_name}
        ),
        Supervisor.child_spec({Cachex, [name: @tag_cache_name] ++ tag_opts},
          id: {Cachex, @tag_cache_name}
        )
      ]
    end

    defp value_cache_opts do
      case Config.cache_config() do
        %{cachex_opts: opts} when is_list(opts) -> opts
        _ -> [router: router(module: Cachex.Router.Ring, options: [monitor: true])]
      end
    end

    @impl Lotus.Cache.Adapter
    def scope, do: :node

    @impl Lotus.Cache.Adapter
    def get(key) do
      case Cachex.get(@cache_name, key) do
        {:ok, nil} -> :miss
        {:ok, value} -> {:ok, decode(value)}
        {:error, _reason} -> :miss
      end
    end

    @impl Lotus.Cache.Adapter
    def put(key, value, ttl_ms, opts) do
      compress = Keyword.get(opts, :compress, true)
      encoded = encode(value, compress)
      max_bytes = Keyword.get(opts, :max_bytes, 5_000_000)

      if byte_size(encoded) <= max_bytes do
        case Cachex.put(@cache_name, key, encoded, expire: ttl_ms) do
          {:ok, true} ->
            store_tags(Keyword.get(opts, :tags, []), key)
            :ok

          {:ok, false} ->
            {:error, :put_failed}

          {:error, reason} ->
            {:error, reason}
        end
      else
        :ok
      end
    end

    @impl Lotus.Cache.Adapter
    def delete(key) do
      Cachex.del(@cache_name, key)

      :ok
    end

    @impl Lotus.Cache.Adapter
    def get_or_store(key, ttl_ms, fun, opts) do
      case get(key) do
        {:ok, value} ->
          {:ok, value, :hit}

        :miss ->
          value = fun.()
          put(key, value, ttl_ms, opts)

          {:ok, value, :miss}
      end
    end

    @impl Lotus.Cache.Adapter
    def invalidate_tags(tags) do
      for tag <- tags, key <- take_tagged_keys(tag) do
        Cachex.del(@cache_name, key)
      end

      :ok
    end

    @impl Lotus.Cache.Adapter
    def touch(key, ttl_ms) do
      Cachex.expire(@cache_name, key, ttl_ms)

      :ok
    end

    defp store_tags(tags, key) do
      for tag <- tags do
        Cachex.get_and_update(@tag_cache_name, tag, fn
          nil -> {:commit, MapSet.new([key])}
          keys -> {:commit, MapSet.put(keys, key)}
        end)
      end

      :ok
    end

    defp take_tagged_keys(tag) do
      case Cachex.take(@tag_cache_name, tag) do
        {:ok, %MapSet{} = keys} -> keys
        _ -> []
      end
    end
  end
end
