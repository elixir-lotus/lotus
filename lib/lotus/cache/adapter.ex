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

  `scope/0` tells `Lotus.Cache` which of those two columns applies. For a
  `:node` adapter the facade relays every `delete/1` and `invalidate_tags/1`
  to the other nodes over `Lotus.Notifier`, where `Lotus.Cache.Relay` applies
  the same call to that node's adapter. Values are never relayed: each node
  fills its own entries on its own misses. A `:cluster` adapter is trusted to
  reach every node by itself and nothing is relayed.

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

  @doc """
  How far one call on this adapter reaches.

    * `:node` — the store is local to the calling node. `delete/1` and
      `invalidate_tags/1` only touch this node's entries, so `Lotus.Cache`
      relays them to the other nodes through `Lotus.Notifier`.
    * `:cluster` — one call reaches every node, because the store is shared
      or the adapter routes its own invalidations. Nothing is relayed.

  Optional. An adapter that does not define it is treated as `:node`, which
  is the safe reading: relaying to a shared store repeats an idempotent
  call, while not relaying to a node-local store leaves stale entries.
  """
  @callback scope() :: :node | :cluster

  @optional_callbacks scope: 0

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
