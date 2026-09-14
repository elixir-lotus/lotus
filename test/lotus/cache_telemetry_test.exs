defmodule Lotus.CacheTelemetryTest do
  use Lotus.CacheCase
  use Mimic

  alias Lotus.Cache
  alias Lotus.Config

  setup :verify_on_exit!

  setup do
    Config
    |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
    |> stub(:cache_namespace, fn -> "test_telemetry" end)

    :ok
  end

  describe "cache telemetry events" do
    test "emits hit event on cache hit" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:lotus, :cache, :hit],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Cache.put("hit_key", "value", 5000)
      Cache.get("hit_key")

      assert_received {:telemetry, [:lotus, :cache, :hit], %{count: 1}, %{key: "hit_key"}}

      :telemetry.detach("#{inspect(ref)}")
    end

    test "emits miss event on cache miss" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:lotus, :cache, :miss],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Cache.get("missing_key")

      assert_received {:telemetry, [:lotus, :cache, :miss], %{count: 1}, %{key: "missing_key"}}

      :telemetry.detach("#{inspect(ref)}")
    end

    test "emits put event on cache put" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:lotus, :cache, :put],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Cache.put("put_key", "value", 5000)

      assert_received {:telemetry, [:lotus, :cache, :put], %{count: 1},
                       %{key: "put_key", ttl_ms: 5000}}

      :telemetry.detach("#{inspect(ref)}")
    end

    test "emits hit event on get_or_store cache hit" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :cache, :hit], [:lotus, :cache, :miss], [:lotus, :cache, :put]],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # First call - miss + put
      Cache.get_or_store("gos_key", 5000, fn -> "computed" end)

      assert_received {:telemetry, [:lotus, :cache, :miss], _, %{key: "gos_key"}}
      assert_received {:telemetry, [:lotus, :cache, :put], _, %{key: "gos_key"}}

      # Second call - hit
      Cache.get_or_store("gos_key", 5000, fn -> "computed" end)

      assert_received {:telemetry, [:lotus, :cache, :hit], _, %{key: "gos_key"}}

      :telemetry.detach("#{inspect(ref)}")
    end
  end
end
