defmodule Lotus.Supervisor do
  @moduledoc """
  Top-level supervisor for Lotus.

  ## Configuration paths

  Lotus can be started in two ways, and each resolves configuration differently:

    * **As an OTP application** (via `Lotus.Application`) — the supervisor is
      started with no opts, so `middleware` and `cache` are read from the
      application environment (`Lotus.Config.middleware/0` and
      `Lotus.Config.cache_config/0`). This is the default when `:lotus` is
      started automatically as a dependency via its OTP application callback.

    * **Embedded in a host supervision tree** (via `child_spec/1`) — opts
      passed to `child_spec/1` (e.g. `middleware:`, `cache:`, `name:`) are
      forwarded to `start_link/1` and override the application environment
      values for that instance. This is the path to use when running multiple
      Lotus instances or when you want per-instance configuration without
      touching the application environment.

  In both cases, opts passed directly to `start_link/1` take precedence over
  application environment config; the `Application.start/2` path simply does
  not pass any opts through.

  ## Children

  In start order: `Lotus.Notifier`, the task supervisor, the cache adapter's
  children (`Lotus.Cache.ETS` when no adapter is configured),
  `Lotus.Cache.Relay`, and `Lotus.Source.Supervisor`. The notifier
  starts first because the relay and the source reconciler listen on it.
  """

  use Supervisor

  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :supervisor_name, Lotus.Supervisor)

    case Supervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @impl true
  def init(opts) do
    Lotus.Config.reload!()

    cache_conf = Keyword.get(opts, :cache, Lotus.Config.cache_config())

    compile_middleware(opts)

    cache_children =
      case cache_conf do
        %{adapter: adapter} -> adapter.spec_config()
        nil -> []
      end

    instance_name = Keyword.get(opts, :name) || Keyword.get(opts, :supervisor_name, Lotus)
    task_sup_name = task_supervisor_name(instance_name)

    children =
      [Lotus.Notifier, {Task.Supervisor, name: task_sup_name}] ++
        default_ets_child(cache_conf) ++
        cache_children ++ [Lotus.Cache.Relay, Lotus.Source.Supervisor]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # With no adapter configured the ETS tables still start, so a host that
  # points `Lotus.Config.cache_adapter/0` at ETS later, or a test that stubs
  # it, finds them. A configured adapter starts what it needs itself, and
  # `Lotus.Cache.Cachex` names its tables the same as ETS, so ETS must not
  # start next to it.
  defp default_ets_child(nil), do: [{Lotus.Cache.ETS, []}]
  defp default_ets_child(_cache_conf), do: []

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, Lotus),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns the task supervisor name for the given Lotus instance name.
  """
  def task_supervisor_name(name) when is_atom(name), do: Module.concat(name, TaskSupervisor)
  def task_supervisor_name(name), do: :"lotus_task_sup_#{:erlang.phash2(name)}"

  defp compile_middleware(opts) do
    middleware_conf = Keyword.get(opts, :middleware, Lotus.Config.middleware())
    if is_map(middleware_conf), do: Lotus.Middleware.compile(middleware_conf)
  end
end
