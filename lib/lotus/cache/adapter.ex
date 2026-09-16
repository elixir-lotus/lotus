defmodule Lotus.Cache.Adapter do
  @moduledoc """
  Behaviour specification for cache adapters in the Lotus framework.

  All cache adapters must implement this behavior.

  Cache adapters are only meant to be used internally by Lotus and should not be
  called directly by application code, as their implementation may change without notice.

  ## Built-in Adapters

  - `Lotus.Cache.ETS` - Default ETS-based local in-memory cache
  - `Lotus.Cache.Cachex` - Cachex-based cache supporting local and distributed modes

  ## Usage

  Simply `use` the behavior in your adapter implementation:

      defmodule MyApp.CustomCacheAdapter do
        use Lotus.Cache.Adapter

        # Implement required callbacks...
      end

  ## Configuration

  Configure your chosen adapter in your application config:

      config :lotus,
        cache: %{
          adapter: MyApp.CustomCacheAdapter,
          # adapter-specific options...
        }

  ## Reach of each callback in a cluster

  Every callback is called on the node that runs the query, with no attempt
  by Lotus to route it elsewhere. What the call reaches depends on the
  adapter's store:

  | Callback | Node-local store (`Lotus.Cache.ETS`) | Shared store (Redis, Cachex with a router) |
  |---|---|---|
  | `get/1`, `put/4`, `touch/2`, `get_or_store/4` | this node's entries | the shared entries |
  | `delete/1` | this node's entry | the shared entry |
  | `invalidate_tags/1` | keys this node tagged | whatever the adapter's tag bookkeeping covers |

  `scope/1` tells `Lotus.Cache` which of those two columns applies to
  `delete/1` and to `invalidate_tags/1`, separately. For an operation the
  adapter answers `:node`, the facade relays the call to the other nodes
  over `Lotus.Notifier`, where `Lotus.Cache.Relay` applies the same call to
  that node's adapter. Values are never relayed: each node fills its own
  entries on its own misses. An operation the adapter answers `:cluster`
  for is trusted to reach every node by itself and is not relayed.

  Tag bookkeeping is bounded by the entries it describes. An adapter drops
  a tag's record of a key once that key has expired, so a tag that is never
  invalidated does not grow for the life of the node.

  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Lotus.Cache.Adapter

      defdelegate encode(value, compress \\ true), to: Lotus.Cache.Adapter
      defdelegate decode(bin), to: Lotus.Cache.Adapter
    end
  end

  @typedoc false
  @type key :: binary()

  @typedoc false
  @type value :: any()

  @typedoc "How long the cache entry should live, in milliseconds"
  @type ttl_ms :: non_neg_integer()

  @typedoc "Options passed to cache operations"
  @type opts :: Keyword.t()

  @doc """
  Returns the adapter specification configuration.

  This should return a keyword list of configuration options specific to the adapter.

  Called by `Lotus.Supervisor` to start the cache adapter under the supervisor.
  """
  @callback spec_config :: list(Supervisor.child_spec()) | list(Supervisor.module_spec())

  @doc """
  Retrieves a value from the cache by key.
  """
  @callback get(key) :: {:ok, value} | :miss | {:error, term}

  @doc """
  Stores a value in the cache with the given key and TTL.
  """
  @callback put(key, value, ttl_ms, opts) :: :ok | {:error, term}

  @doc """
  Removes a value from the cache by key.
  """
  @callback delete(key) :: :ok | {:error, term}

  @doc """
  Retrieves a value from cache or stores it if missing.
  """
  @callback get_or_store(key, ttl_ms, (-> value), opts) ::
              {:ok, value, :hit | :miss} | {:error, term}

  @doc """
  Invalidates all cache entries associated with the given tags.

  Tags allow for bulk invalidation of related cache entries. When a tag is
  invalidated, all cache entries that were stored with that tag are removed.

  ## Parameters

  - `tags` - List of tag names to invalidate
  """
  @callback invalidate_tags([binary()]) :: :ok | {:error, term}

  @doc """
  Updates the TTL of an existing cache entry without modifying its value.
  """
  @callback touch(key, ttl_ms) :: :ok | {:error, term}

  @typedoc "The two operations `Lotus.Cache` relays when they are node-local."
  @type relayed_operation :: :delete | :invalidate_tags

  @doc """
  How far one call of `operation` on this adapter reaches.

    * `:node` — the call only touches this node's entries, so `Lotus.Cache`
      relays it to the other nodes through `Lotus.Notifier`.
    * `:cluster` — one call reaches every node, because the store is shared
      or the adapter routes the call itself. Nothing is relayed.

  The answer is per operation because an adapter can route single-key
  deletes to a shared store while it keeps tag bookkeeping on each node.

  Optional. An adapter that does not define it is treated as `:node` for
  both operations, which is the safe reading: relaying to a shared store
  repeats an idempotent call, while not relaying to a node-local store
  leaves stale entries.
  """
  @callback scope(relayed_operation()) :: :node | :cluster

  @optional_callbacks scope: 1

  @doc """
  Encodes a value into a binary for storage.

  The `compress` flag indicates whether to use compression.
  """
  def encode(value, compress) do
    if compress do
      :erlang.term_to_binary(value, [:compressed])
    else
      :erlang.term_to_binary(value)
    end
  end

  @doc """
  Decodes a binary back into its original term.
  """
  def decode(bin), do: :erlang.binary_to_term(bin, [:safe])
end
