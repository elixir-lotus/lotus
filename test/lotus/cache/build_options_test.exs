defmodule Lotus.Cache.BuildOptionsTest do
  @moduledoc """
  `:max_bytes`, `:compress` and `:lock_timeout` are deployment policy, so they
  are read from `:cache` config. A per-call `:cache` option overrides them.
  """

  use ExUnit.Case, async: false

  alias Lotus.Cache

  setup do
    original = Application.get_env(:lotus, :cache)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lotus, :cache)
        config -> Application.put_env(:lotus, :cache, config)
      end

      Lotus.Config.reload!()
    end)

    :ok
  end

  defp put_cache_config(extra) do
    base = Application.get_env(:lotus, :cache) || %{}
    Application.put_env(:lotus, :cache, Map.merge(base, extra))
    Lotus.Config.reload!()
  end

  test "entry options set in config reach the adapter" do
    put_cache_config(%{max_bytes: 1_000, compress: false, lock_timeout: 250})

    opts = Cache.build_options(nil, ["source:postgres"])

    assert opts[:max_bytes] == 1_000
    assert opts[:compress] == false
    assert opts[:lock_timeout] == 250
    assert opts[:tags] == ["source:postgres"]
  end

  test "a per-call cache option overrides config" do
    put_cache_config(%{max_bytes: 1_000, compress: false})

    opts = Cache.build_options([max_bytes: 50_000], [])

    assert opts[:max_bytes] == 50_000
    assert opts[:compress] == false
  end

  test "an unset key is left out, so the adapter default applies" do
    put_cache_config(%{max_bytes: 1_000})

    opts = Cache.build_options([], [])

    assert opts[:max_bytes] == 1_000
    refute Keyword.has_key?(opts, :compress)
    refute Keyword.has_key?(opts, :lock_timeout)
  end

  test "an atom cache option still picks up the configured defaults" do
    put_cache_config(%{compress: false})

    opts = Cache.build_options(:bypass, ["query:1"])

    assert opts[:compress] == false
    assert opts[:tags] == ["query:1"]
  end

  test "with no cache config at all the options carry only the tags" do
    Application.delete_env(:lotus, :cache)
    Lotus.Config.reload!()

    assert Cache.build_options(nil, ["source:x"]) == [tags: ["source:x"]]
  end
end
