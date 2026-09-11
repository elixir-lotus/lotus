defmodule Lotus.Cache.Key do
  @moduledoc """
  Cache key construction for query results and schema introspection.

  Keys are opaque binaries built from the statement, its bound values, the
  data source and any caller-supplied cache identity. `Lotus.Cache.KeyBuilder`
  is the extension point for hosts that need a different scheme.
  """

  @spec result(term(), map() | list(), keyword(), term() | nil) :: binary()
  def result(body, bound, opts, scope \\ nil) do
    Lotus.Config.cache_key_builder().result_key(body, bound, opts, scope)
  end
end
