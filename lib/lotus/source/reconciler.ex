defmodule Lotus.Source.Reconciler do
  @moduledoc false

  # Serializes reconciles and remembers the adapter struct of every source it
  # started, so a source that has already left the resolver can still be
  # stopped through `source_stopped/2` with the state it was started with.

  use GenServer

  require Logger

  alias Lotus.Source.Adapter
  alias Lotus.Source.ChildSupervisor

  @call_timeout :timer.seconds(60)

  @type result :: {:ok, Lotus.Source.Supervisor.report()} | {:error, term()}

  defstruct running: %{}, suspended: MapSet.new()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reconcile() :: result()
  def reconcile, do: GenServer.call(__MODULE__, :reconcile, @call_timeout)

  @spec suspend(String.t()) :: result()
  def suspend(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:suspend, name}, @call_timeout)
  end

  @spec resume(String.t()) :: result()
  def resume(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:resume, name}, @call_timeout)
  end

  @spec running?(String.t()) :: boolean()
  def running?(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:running?, name}, @call_timeout)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    case do_reconcile(state) do
      {{:ok, _report}, state} ->
        {:noreply, state}

      {{:error, reason}, state} ->
        Logger.warning(
          "Lotus could not reconcile its sources at boot: #{inspect(reason)}. " <>
            "Call Lotus.Source.reconcile/0 once the source resolver is ready."
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {reply, state} = do_reconcile(state)
    {:reply, reply, state}
  end

  def handle_call({:suspend, name}, _from, state) do
    {reply, state} = do_reconcile(%{state | suspended: MapSet.put(state.suspended, name)})
    {:reply, reply, state}
  end

  def handle_call({:resume, name}, _from, state) do
    {reply, state} = do_reconcile(%{state | suspended: MapSet.delete(state.suspended, name)})
    {:reply, reply, state}
  end

  def handle_call({:running?, name}, _from, state) do
    {:reply, Map.has_key?(state.running, name), state}
  end

  defp do_reconcile(state) do
    case list_sources() do
      {:ok, adapters} ->
        known_names = MapSet.new(adapters, & &1.name)
        suspended = MapSet.filter(state.suspended, &MapSet.member?(known_names, &1))
        desired = desired(adapters, suspended)

        {state, stopped} = stop_stale(state, desired)
        {state, started, failed} = start_missing(state, desired)
        stop_unused_shared(state)

        report = %{started: started, stopped: stopped, failed: failed}
        {{:ok, report}, %{state | suspended: suspended}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp list_sources do
    {:ok, Lotus.Config.source_resolver().list_sources()}
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp desired(adapters, suspended) do
    adapters
    |> Enum.reject(&MapSet.member?(suspended, &1.name))
    |> Enum.uniq_by(& &1.name)
    |> Map.new(&{&1.name, &1})
  end

  defp stop_stale(state, desired) do
    running_ids = ChildSupervisor.running_ids()

    {running, stopped} =
      Enum.reduce(state.running, {state.running, []}, fn {name, entry}, {running, stopped} ->
        if up_to_date?(entry, Map.get(desired, name), running_ids) do
          {running, stopped}
        else
          stop_source(entry.adapter)
          {Map.delete(running, name), [name | stopped]}
        end
      end)

    {%{state | running: running}, Enum.reverse(stopped)}
  end

  defp up_to_date?(_entry, nil, _running_ids), do: false

  defp up_to_date?(%{adapter: started} = entry, %Adapter{} = wanted, running_ids) do
    started.module == wanted.module and started.state == wanted.state and
      (not entry.children? or MapSet.member?(running_ids, source_id(started)))
  end

  defp start_missing(state, desired) do
    Enum.reduce(desired, {state, [], []}, fn {name, adapter}, {state, started, failed} ->
      if Map.has_key?(state.running, name) do
        {state, started, failed}
      else
        case start_source(adapter) do
          {:ok, children?} ->
            entry = %{adapter: adapter, children?: children?}
            {put_in(state.running[name], entry), [name | started], failed}

          {:error, reason} ->
            Logger.warning("Lotus could not start source #{inspect(name)}: #{inspect(reason)}")
            {state, started, [{name, reason} | failed]}
        end
      end
    end)
    |> then(fn {state, started, failed} ->
      {state, Enum.reverse(started), Enum.reverse(failed)}
    end)
  end

  defp start_source(%Adapter{module: module} = adapter) do
    with :ok <- ensure_shared(module),
         {:ok, children?} <- start_children(adapter),
         :ok <- run_started_hook(adapter, children?) do
      {:ok, children?}
    end
  end

  defp ensure_shared(module) do
    if MapSet.member?(ChildSupervisor.running_ids(), {:shared, module}) do
      :ok
    else
      with {:ok, specs} <- safely(fn -> Adapter.shared_children(module) end) do
        case specs do
          [] -> :ok
          specs -> ChildSupervisor.start({:shared, module}, specs)
        end
      end
    end
  end

  defp start_children(%Adapter{} = adapter) do
    with {:ok, specs} <- safely(fn -> Adapter.source_children(adapter) end) do
      case specs do
        [] ->
          {:ok, false}

        specs ->
          with :ok <- ChildSupervisor.start(source_id(adapter), specs) do
            {:ok, true}
          end
      end
    end
  end

  defp run_started_hook(%Adapter{} = adapter, children?) do
    case safely(fn -> Adapter.source_started(adapter) end) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if children?, do: ChildSupervisor.stop(source_id(adapter))
        {:error, reason}
    end
  end

  defp stop_source(%Adapter{name: name} = adapter) do
    case safely(fn -> Adapter.source_stopped(adapter) end) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Lotus source #{inspect(name)} raised in source_stopped/2: #{inspect(reason)}"
        )
    end

    ChildSupervisor.stop(source_id(adapter))
  end

  defp stop_unused_shared(state) do
    in_use = MapSet.new(state.running, fn {_name, entry} -> entry.adapter.module end)

    for {:shared, module} = id <- ChildSupervisor.ids(),
        not MapSet.member?(in_use, module) do
      ChildSupervisor.stop(id)
    end

    :ok
  end

  defp source_id(%Adapter{module: module, name: name}), do: {:source, module, name}

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
