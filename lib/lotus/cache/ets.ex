defmodule Lotus.Cache.ETS do
  @moduledoc """
  An ETS-based, local, in-memory cache adapter for Lotus.

  This is the default cache adapter if none is specified.

  If you want a distributed cache, consider using `Lotus.Cache.Cachex`.
  """

  use GenServer
  use Lotus.Cache.Adapter

  @table :lotus_cache
  @tag_table :lotus_cache_tags
  @janitor_interval :timer.seconds(30)

  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@tag_table, [:bag, :named_table, :public, write_concurrency: true])

    schedule_janitor()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:run_janitor, state) do
    now = now_ms()
    :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:"=<", :"$3", now}], [true]}])
    schedule_janitor()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_janitor do
    Process.send_after(self(), :run_janitor, @janitor_interval)
  end

  @impl Lotus.Cache.Adapter
  def spec_config do
    [{Lotus.Cache.ETS, []}]
  end

  @impl Lotus.Cache.Adapter
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value_bin, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(@table, key)
          :miss
        else
          {:ok, decode(value_bin)}
        end

      _ ->
        :miss
    end
  end

  @impl Lotus.Cache.Adapter
  def put(key, value, ttl_ms, opts) do
    compress = Keyword.get(opts, :compress, true)
    encoded = encode(value, compress)

    max_bytes = Keyword.get(opts, :max_bytes, 5_000_000)
    if byte_size(encoded) > max_bytes, do: :ok, else: do_put(key, encoded, ttl_ms, opts)
  end

  defp do_put(key, bin, ttl_ms, opts) do
    expires_at = now_ms() + ttl_ms
    :ets.insert(@table, {key, bin, expires_at})
    for t <- Keyword.get(opts, :tags, []), do: :ets.insert(@tag_table, {t, key})
    :ok
  end

  @impl Lotus.Cache.Adapter
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl Lotus.Cache.Adapter
  def touch(key, ttl_ms) do
    case :ets.lookup(@table, key) do
      [{^key, v, _old}] ->
        :ets.insert(@table, {key, v, now_ms() + ttl_ms})
        :ok

      _ ->
        :ok
    end
  end

  @impl Lotus.Cache.Adapter
  def get_or_store(key, ttl_ms, fun, opts) do
    case get(key) do
      {:ok, v} ->
        {:ok, v, :hit}

      :miss ->
        lock = {:lotus_cache_lock, key}

        case :global.set_lock(lock, [node()], Keyword.get(opts, :lock_timeout, 10_000)) do
          true ->
            try do
              case get(key) do
                {:ok, v} ->
                  {:ok, v, :hit}

                :miss ->
                  value = fun.()
                  put(key, value, ttl_ms, opts)
                  {:ok, value, :miss}
              end
            after
              :global.del_lock(lock)
            end

          false ->
            value = fun.()
            {:ok, value, :miss}
        end
    end
  end

  @impl Lotus.Cache.Adapter
  def invalidate_tags(tags) do
    for tag <- tags do
      for {^tag, key} <- :ets.lookup(@tag_table, tag) do
        :ets.delete(@table, key)
        :ets.delete_object(@tag_table, {tag, key})
      end
    end

    :ok
  end

  defp expired?(ts), do: ts <= now_ms()
  defp now_ms, do: System.monotonic_time(:millisecond)
end
