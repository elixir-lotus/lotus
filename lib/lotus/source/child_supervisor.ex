defmodule Lotus.Source.ChildSupervisor do
  @moduledoc false

  use Supervisor

  @type id :: {:shared, module()} | {:source, module(), String.t()}
  @type child_spec :: Supervisor.child_spec() | {module(), term()} | module()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end

  @doc """
  Starts `specs` under their own supervisor, registered as `id`.

  Each group gets a nested `one_for_one` supervisor so that a group whose
  children crash past their restart limit takes down only that group. The
  nested supervisor is `:transient`: it is not restarted after that, and
  the next reconcile starts it again.
  """
  @spec start(id(), [child_spec()]) :: :ok | {:error, term()}
  def start(id, specs) when is_list(specs) do
    spec = %{
      id: id,
      start: {Supervisor, :start_link, [specs, [strategy: :one_for_one]]},
      type: :supervisor,
      restart: :transient
    }

    case Supervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        with :ok <- Supervisor.delete_child(__MODULE__, id) do
          start(id, specs)
        end

      {:error, {reason, child}} when is_tuple(child) and elem(child, 0) == :child ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops and forgets the group registered as `id`. Unknown ids are ignored.
  """
  @spec stop(id()) :: :ok
  def stop(id) do
    _ = Supervisor.terminate_child(__MODULE__, id)
    _ = Supervisor.delete_child(__MODULE__, id)
    :ok
  end

  @doc """
  Ids of every group the supervisor knows, running or not.
  """
  @spec ids() :: MapSet.t(id())
  def ids do
    __MODULE__
    |> Supervisor.which_children()
    |> MapSet.new(fn {id, _pid, _type, _modules} -> id end)
  end

  @doc """
  Ids of the groups whose supervisor is alive.
  """
  @spec running_ids() :: MapSet.t(id())
  def running_ids do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    |> MapSet.new(fn {id, _pid, _type, _modules} -> id end)
  end
end
