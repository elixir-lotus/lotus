defmodule Lotus.Cache.KeyBuilder do
  @moduledoc """
  Behaviour for building cache keys in Lotus.

  Implement this behaviour to customize how cache keys are generated for
  discovery (schema introspection) and result (query execution) caching.

  The default implementation (`Lotus.Cache.KeyBuilder.Default`) preserves
  the existing key generation logic.

  ## Configuration

      config :lotus,
        cache: %{
          adapter: Lotus.Cache.ETS,
          key_builder: MyApp.CustomKeyBuilder
        }

  ## Example

      defmodule MyApp.CustomKeyBuilder do
        @behaviour Lotus.Cache.KeyBuilder

        @impl true
        def discovery_key(params, scope) do
          # Custom key logic for discovery cache entries
          Lotus.Cache.KeyBuilder.Default.discovery_key(params, scope)
        end

        @impl true
        def result_key(body, bound, opts, scope) do
          # Custom key logic for result cache entries
          Lotus.Cache.KeyBuilder.Default.result_key(body, bound, opts, scope)
        end
      end
  """

  @type discovery_params :: %{
          kind: atom(),
          source_name: binary(),
          components: tuple(),
          version: binary()
        }

  @doc """
  Builds a cache key for discovery (schema introspection) entries.

  ## Parameters

  - `params` - A map containing:
    - `:kind` - The discovery operation (e.g. `:list_schemas`, `:list_tables`)
    - `:source_name` - The data source name
    - `:components` - A tuple of additional key components specific to the kind
    - `:version` - The Lotus version string
  - `scope` - The scope term, or `nil` if no scope is set
  """
  @callback discovery_key(params :: discovery_params(), scope :: term() | nil) :: binary()

  @doc """
  Builds a cache key for query result entries.

  ## Parameters

  - `body` - The adapter-native query payload. `term()` by design: a SQL
    string for Ecto adapters, a DSL / AST / JSON payload for others
  - `bound` - Bound parameters (map or list)
  - `opts` - Options including `:data_source`, `:search_path`, `:lotus_version`
    and `:read_only` (whether the run was read-only: an entry a read-write
    run stored must not serve a read-only one)
  - `scope` - The scope term, or `nil` if no scope is set
  """
  @callback result_key(
              body :: term(),
              bound :: map() | list(),
              opts :: keyword(),
              scope :: term() | nil
            ) :: binary()

  @doc """
  Computes a 16-character hex digest for the given scope term.

  Returns an empty string when `scope` is `nil`. Used for building
  scope-specific cache keys and tags.

  ## Examples

      iex> Lotus.Cache.KeyBuilder.scope_digest(nil)
      ""

      iex> digest = Lotus.Cache.KeyBuilder.scope_digest(%{tenant_id: 42})
      iex> is_binary(digest) and byte_size(digest) == 16
      true
  """
  @spec scope_digest(term()) :: binary()
  def scope_digest(nil), do: ""

  def scope_digest(scope) do
    :crypto.hash(:sha256, :erlang.term_to_binary(scope))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
