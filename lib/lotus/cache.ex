defmodule Lotus.Cache do
  @moduledoc """
  Lotus cache facade. If no adapter configured, acts as a no-op pass-through.
  """

  alias Lotus.Cache.KeyBuilder
  alias Lotus.{Config, Telemetry}

  @type key :: binary()
  @type value :: any()
  @type ttl_ms :: non_neg_integer()
  @type opts :: Keyword.t()

  @spec enabled?() :: boolean()
  def enabled?, do: match?({:ok, _}, adapter())

  @doc """
  Builds the per-entry options for a cache write.

  Layers the caller's `:cache` option over the entry options set in
  application config, then adds the invalidation tags. A caller that passes
  no `:cache` option, or an atom such as `:bypass`, still gets the
  configured defaults.
  """
  @spec build_options(term(), [String.t()]) :: opts()
  def build_options(cache_opts, tags) do
    Config.cache_entry_options()
    |> Keyword.merge(per_call_options(cache_opts))
    |> Keyword.put(:tags, tags)
  end

  defp per_call_options(cache_opts) when is_list(cache_opts) do
    cache_opts
    |> Enum.filter(&match?({_key, _value}, &1))
    |> Keyword.take([:max_bytes, :compress, :lock_timeout])
  end

  defp per_call_options(_cache_opts), do: []

  @spec get(key) :: {:ok, value} | :miss
  def get(key) do
    case adapter() do
      {:ok, adapter} ->
        case adapter.get(ns(key)) do
          {:ok, _} = hit ->
            Telemetry.cache_hit(key)
            hit

          :miss ->
            Telemetry.cache_miss(key)
            :miss
        end

      _ ->
        :miss
    end
  end

  @spec get_or_store(key, ttl_ms, (-> value), opts) ::
          {:ok, value, :hit | :miss | atom()} | {:error, term}
  def get_or_store(key, ttl_ms, fun, opts \\ []) do
    case adapter() do
      {:ok, adapter} ->
        case adapter.get_or_store(ns(key), ttl_ms, fun, opts) do
          {:ok, _val, :hit} = result ->
            Telemetry.cache_hit(key)
            result

          {:ok, _val, _miss_or_other} = result ->
            Telemetry.cache_miss(key)
            Telemetry.cache_put(key, ttl_ms)
            result

          other ->
            other
        end

      _ ->
        {:ok, fun.(), :miss}
    end
  end

  @spec put(key, value, ttl_ms, opts) :: :ok | {:error, term}
  def put(key, value, ttl_ms, opts \\ []) do
    case adapter() do
      {:ok, adapter} ->
        result = adapter.put(ns(key), value, ttl_ms, opts)
        Telemetry.cache_put(key, ttl_ms)
        result

      _ ->
        :ok
    end
  end

  @spec delete(key) :: :ok | {:error, term}
  def delete(key) do
    case adapter() do
      {:ok, adapter} -> adapter.delete(ns(key))
      _ -> :ok
    end
  end

  @doc """
  Invalidates all cache entries associated with the given scope.

  Uses tag-based invalidation — each scoped cache entry is tagged with
  `"scope:<digest>"`, so this clears only entries for the specified scope
  without flushing the entire source cache.

  ## Examples

      Lotus.Cache.invalidate_scope(%{tenant_id: 42})
      Lotus.Cache.invalidate_scope(%{role: :admin})
  """
  @spec invalidate_scope(term()) :: :ok | {:error, term}
  def invalidate_scope(nil), do: :ok

  def invalidate_scope(scope) do
    invalidate_tags(["scope:#{KeyBuilder.scope_digest(scope)}"])
  end

  @spec invalidate_tags([binary()]) :: :ok | {:error, term}
  def invalidate_tags(tags) when is_list(tags) do
    with {:ok, adapter} <- adapter(),
         true <- function_exported?(adapter, :invalidate_tags, 1) do
      adapter.invalidate_tags(tags)
    else
      _ -> :ok
    end
  end

  defp ns(key), do: "#{namespace()}:#{key}"

  defp namespace, do: Config.cache_namespace()

  defp adapter, do: Config.cache_adapter()
end
