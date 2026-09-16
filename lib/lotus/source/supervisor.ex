defmodule Lotus.Source.Supervisor do
  @moduledoc """
  Supervises the processes that source adapters own.

  `Lotus.Supervisor` starts this tree. It holds `Lotus.Source.Registry`, a
  supervisor for the children adapters return from
  `c:Lotus.Source.Adapter.shared_children/0` and
  `c:Lotus.Source.Adapter.source_children/2`, and a reconciler that keeps
  those children in step with the sources the configured
  `Lotus.Source.Resolver` lists.

  ## Reconciling

  `reconcile/0` reads `list_sources/0` from the resolver and diffs it against
  what is running:

    * a source that is new, or whose adapter module or state changed, gets
      its children started and `source_started/2` called;
    * a source that is gone, or changed, has `source_stopped/2` called and
      its children stopped first;
    * the shared children of an adapter module start with the first source
      of that module and stop with the last one.

  Boot runs the first reconcile. A resolver that changes its sources at
  runtime calls `Lotus.Source.reconcile/0` after every change. That call
  reconciles the local node and notifies the other nodes over
  `Lotus.Notifier`, so each of them reconciles against its own view of the
  resolver. `reconcile/0` on this module is the node-local half.

  A resolver that is not ready at boot, because it reads a database whose
  repo starts after `:lotus`, makes the boot reconcile log a warning and
  do nothing. Call `Lotus.Source.reconcile/0` when it is ready.

  ## Suspending a source

  `suspend/1` stops a source's children and keeps them stopped across
  reconciles while the source stays listed by the resolver. `resume/1`
  starts them again. This is how an idle policy stops a source it still
  knows about without removing it. A suspended name that disappears from the
  resolver is forgotten. Both calls are node-local and are not relayed:
  whether a source is idle is a per-node fact.

  ## Failures

  A source whose children fail to start, or whose `source_started/2` raises,
  is reported under `:failed`, logged, and tried again on the next
  reconcile. Other sources are not affected. Each source's children run
  under their own supervisor, so one source crashing past its restart
  limit does not take the others down.
  """

  use Supervisor

  alias Lotus.Source.Reconciler

  @typedoc """
  What a reconcile did: the names it started, the names it stopped and the
  names it could not start with the reason.
  """
  @type report :: %{
          started: [String.t()],
          stopped: [String.t()],
          failed: [{String.t(), term()}]
        }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @impl true
  def init(_opts) do
    children = [
      Lotus.Source.Registry,
      Lotus.Source.ChildSupervisor,
      Lotus.Source.Reconciler
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts and stops adapter-owned processes so they match the resolver's
  sources.
  """
  @spec reconcile() :: {:ok, report()} | {:error, term()}
  defdelegate reconcile(), to: Reconciler

  @doc """
  Stops the children of `name` and keeps them stopped until `resume/1`.
  """
  @spec suspend(String.t()) :: {:ok, report()} | {:error, term()}
  defdelegate suspend(name), to: Reconciler

  @doc """
  Lifts a `suspend/1` and starts the children of `name` again.
  """
  @spec resume(String.t()) :: {:ok, report()} | {:error, term()}
  defdelegate resume(name), to: Reconciler

  @doc """
  Whether `name` is started: its children are up and `source_started/2` ran.
  """
  @spec running?(String.t()) :: boolean()
  defdelegate running?(name), to: Reconciler
end
