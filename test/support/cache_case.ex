defmodule Lotus.CacheCase do
  @moduledoc """
  This module defines the setup for cache-related tests.

  `Lotus.Cache.ETS` is a named GenServer that owns the cache tables. ExUnit
  starts a supervised instance per test, which guarantees the GenServer (and
  its ETS tables) are torn down cleanly between tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Lotus.CacheCase
    end
  end

  setup do
    start_supervised!(Lotus.Cache.ETS)
    :ok
  end
end
