defmodule Lotus.Cache.Relay do
  @moduledoc """
  Applies cache invalidations sent by other nodes to this node's adapter.

  `Lotus.Cache.delete/1` and `Lotus.Cache.invalidate_tags/1` apply their
  change locally and, when the configured adapter is node-local
  (`Lotus.Cache.scope/0` returns `:node`), send it on the `:cache` topic of
  `Lotus.Notifier`. This process listens on that topic on every node and
  calls the same adapter function locally, without notifying again. Values never travel: a node whose entry was dropped fills it on its
  next miss.

  `Lotus.Supervisor` starts one relay per node after the cache adapter.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @impl GenServer
  def init(_opts) do
    Lotus.Notifier.listen(:cache)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:lotus_notification, :cache, payload}, state) do
    Lotus.Cache.apply_relayed(payload)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
