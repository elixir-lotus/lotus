defmodule Lotus.Notifier do
  @moduledoc """
  Tells the other nodes of a cluster that something changed on this one.

  Lotus keeps some state per node: cache entries, the tag bookkeeping behind
  them, the processes a source adapter owns, and whatever a resolver caches.
  A change made on one node, such as a tag invalidation or a source added
  from an admin screen, has to reach every node. This module carries those
  notifications between nodes. Core uses it for cache invalidation and
  source reconciliation, and it is the channel that sources, visibility
  rules and settings edited at runtime will use so that every node reacts.
  A host or an extension listens on its own topics for the state it keeps.

  ## How it works

  The transport is OTP process groups, the `:pg` module of the `kernel`
  application. `Lotus.Supervisor` starts a `:pg` scope named `Lotus.Notifier`
  as its first child. Nothing is added to the dependency list and nothing is
  configured: nodes connected through distributed Erlang share the scope
  automatically. A topic is a `:pg` group; `listen/1` joins the calling process
  to it and `notify/3` sends `{:lotus_notification, topic, payload}` to every
  listener on every node.

  Before `Lotus.Supervisor` has started the scope, `notify/3` delivers to
  nobody and returns `:ok`, and `listen/1` exits with `:noproc`. A cache
  delete or a source invalidation made from a host's own start phase or
  from a release task applies to that node alone.

  Only notifications travel, never values. A node that receives one applies
  it to its own state. Delivery is best-effort, like any Erlang message
  send: a node that is partitioned away misses the notification and relies
  on cache TTLs and its next reconcile.

  ## Topics core uses

    * `:cache` — `{:invalidate_tags, tags}` and `{:delete, key}`, sent by
      `Lotus.Cache` when the configured adapter is node-local and applied by
      `Lotus.Cache.Relay` on every other node.
    * `:sources` — `:reconcile` and `{:invalidate, name}`, sent by
      `Lotus.Source.reconcile/0` and `Lotus.Source.invalidate/1` and applied
      by the source reconciler on every other node.

  ## Using it from a host

  A process that keeps per-node state listens on a topic and handles the
  message:

      defmodule MyApp.VisibilityStore do
        use GenServer

        def init(state) do
          Lotus.Notifier.listen({MyApp, :visibility})
          {:ok, state}
        end

        def handle_info({:lotus_notification, {MyApp, :visibility}, {:changed, source}}, state) do
          {:noreply, reload(state, source)}
        end
      end

  The node that made the change applies it locally and then tells the
  others:

      MyApp.VisibilityStore.write(source, rules)
      Lotus.Notifier.notify({MyApp, :visibility}, {:changed, source}, except: [node()])

  Pick topic names that cannot clash with core's: prefix them with the
  application name, or use a tuple such as `{MyApp, :visibility}`.
  """

  @scope __MODULE__

  @typedoc "A topic is any term. Core uses atoms."
  @type topic :: term()

  @typedoc "The message a listener receives."
  @type notification :: {:lotus_notification, topic(), payload :: term()}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_opts \\ []) do
    case :pg.start_link(@scope) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @doc """
  Joins the calling process to `topic`.

  The process receives `{:lotus_notification, topic, payload}` for every
  `notify/3` on that topic until it leaves with `unlisten/1` or exits.
  Joining twice delivers every notification twice.
  """
  @spec listen(topic()) :: :ok
  def listen(topic), do: :pg.join(@scope, topic, self())

  @doc """
  Removes the calling process from `topic`.
  """
  @spec unlisten(topic()) :: :ok
  def unlisten(topic) do
    _ = :pg.leave(@scope, topic, self())
    :ok
  end

  @doc """
  Sends `{:lotus_notification, topic, payload}` to every listener of `topic`
  on every connected node.

  ## Options

    * `:except` — nodes whose listeners are skipped. Pass `[node()]` when
      the caller has already applied the change locally and only the other
      nodes have to hear about it.
  """
  @spec notify(topic(), term(), keyword()) :: :ok
  def notify(topic, payload, opts \\ []) do
    skip = Keyword.get(opts, :except, [])
    message = {:lotus_notification, topic, payload}

    for pid <- :pg.get_members(@scope, topic), node(pid) not in skip do
      send(pid, message)
    end

    :ok
  end

  @doc """
  Returns the pids listening on `topic` across the cluster.
  """
  @spec listeners(topic()) :: [pid()]
  def listeners(topic), do: :pg.get_members(@scope, topic)
end
