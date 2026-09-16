defmodule Lotus.Source.SupervisorTest do
  # The reconciler and the registry are singletons started by the
  # application, and the tests swap the global source resolver.
  use ExUnit.Case, async: false

  alias Lotus.Source.Adapters.Postgres
  alias Lotus.Source.ChildSupervisor
  alias Lotus.Source.Registry
  alias Lotus.Test.LifecycleAdapter
  alias Lotus.Test.LifecycleResolver

  setup do
    previous = Application.get_env(:lotus, :source_resolver)
    Application.put_env(:lotus, :source_resolver, LifecycleResolver)
    Lotus.Config.reload!()
    LifecycleResolver.put_sources([])
    {:ok, _} = Lotus.Source.reconcile()

    on_exit(fn ->
      LifecycleResolver.put_sources([])
      {:ok, _} = Lotus.Source.reconcile()
      LifecycleResolver.clear()

      case previous do
        nil -> Application.delete_env(:lotus, :source_resolver)
        resolver -> Application.put_env(:lotus, :source_resolver, resolver)
      end

      Lotus.Config.reload!()
    end)

    :ok
  end

  defp source(name, extra \\ %{}) do
    LifecycleAdapter.wrap(name, Map.merge(%{owner: self()}, extra))
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp shared_pid, do: Process.whereis(LifecycleAdapter.shared_name())

  describe "cluster notifications" do
    setup do
      :ok = Lotus.Notifier.listen(:sources)
      on_exit(fn -> Lotus.Notifier.unlisten(:sources) end)
      :ok
    end

    test "Lotus.Source.reconcile/0 reconciles this node without notifying its own listeners" do
      name = uniq("local")
      LifecycleResolver.put_sources([source(name)])

      assert {:ok, %{started: [^name]}} = Lotus.Source.reconcile()

      refute_receive {:lotus_notification, :sources, :reconcile}
    end

    test "a :reconcile notification from another node reconciles this node" do
      name = uniq("remote")
      LifecycleResolver.put_sources([source(name)])

      send(Lotus.Source.Reconciler, {:lotus_notification, :sources, :reconcile})
      :sys.get_state(Lotus.Source.Reconciler)

      assert Lotus.Source.Supervisor.running?(name)
      assert_receive {:source_started, ^name}
    end

    test "an {:invalidate, name} notification from another node reaches the resolver" do
      send(Lotus.Source.Reconciler, {:lotus_notification, :sources, {:invalidate, "acme"}})
      :sys.get_state(Lotus.Source.Reconciler)

      assert Process.alive?(Process.whereis(Lotus.Source.Reconciler))
    end

    test "the reconciler ignores an unrelated message" do
      send(Lotus.Source.Reconciler, :unrelated)

      assert %Lotus.Source.Reconciler{} = :sys.get_state(Lotus.Source.Reconciler)
    end
  end

  describe "reconcile/0" do
    test "starts shared and per-source children and runs the started hook" do
      name = uniq("warehouse")
      LifecycleResolver.put_sources([source(name)])

      assert {:ok, %{started: [^name], stopped: [], failed: []}} = Lotus.Source.reconcile()

      assert is_pid(shared_pid())
      assert pid = Registry.whereis(LifecycleAdapter, name)
      assert Agent.get(pid, & &1) == %{owner: self()}
      assert_received {:source_started, ^name}
      assert Lotus.Source.Supervisor.running?(name)
    end

    test "a second reconcile with the same sources changes nothing" do
      name = uniq("warehouse")
      LifecycleResolver.put_sources([source(name)])
      {:ok, _} = Lotus.Source.reconcile()
      pid = Registry.whereis(LifecycleAdapter, name)
      assert_received {:source_started, ^name}

      assert {:ok, %{started: [], stopped: [], failed: []}} = Lotus.Source.reconcile()

      assert Registry.whereis(LifecycleAdapter, name) == pid
      refute_received {:source_started, _}
      refute_received {:source_stopped, _}
    end

    test "stops a source that left the resolver and runs the stopped hook first" do
      name = uniq("warehouse")
      LifecycleResolver.put_sources([source(name)])
      {:ok, _} = Lotus.Source.reconcile()
      pid = Registry.whereis(LifecycleAdapter, name)
      ref = Process.monitor(pid)

      LifecycleResolver.put_sources([])
      assert {:ok, %{started: [], stopped: [^name], failed: []}} = Lotus.Source.reconcile()

      assert_received {:source_stopped, ^name}
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Registry.whereis(LifecycleAdapter, name) == nil
      refute Lotus.Source.Supervisor.running?(name)
    end

    test "shared children start with the first source of a module and stop with the last" do
      first = uniq("first")
      second = uniq("second")
      LifecycleResolver.put_sources([source(first), source(second)])
      {:ok, _} = Lotus.Source.reconcile()
      shared = shared_pid()
      assert is_pid(shared)

      LifecycleResolver.put_sources([source(second)])
      {:ok, _} = Lotus.Source.reconcile()
      assert shared_pid() == shared

      LifecycleResolver.put_sources([])
      {:ok, _} = Lotus.Source.reconcile()
      assert shared_pid() == nil
      assert ChildSupervisor.ids() == MapSet.new()
    end

    test "restarts a source whose state changed" do
      name = uniq("warehouse")
      LifecycleResolver.put_sources([source(name, %{url: "one"})])
      {:ok, _} = Lotus.Source.reconcile()
      old_pid = Registry.whereis(LifecycleAdapter, name)
      assert_received {:source_started, ^name}

      LifecycleResolver.put_sources([source(name, %{url: "two"})])
      assert {:ok, %{started: [^name], stopped: [^name]}} = Lotus.Source.reconcile()

      assert_received {:source_stopped, ^name}
      assert_received {:source_started, ^name}
      new_pid = Registry.whereis(LifecycleAdapter, name)
      assert new_pid != old_pid
      assert Agent.get(new_pid, & &1.url) == "two"
    end

    test "a source with hooks but no children is started and stopped through the hooks" do
      name = uniq("hooks-only")
      LifecycleResolver.put_sources([source(name, %{children: :none})])

      assert {:ok, %{started: [^name]}} = Lotus.Source.reconcile()
      assert_received {:source_started, ^name}
      assert Registry.whereis(LifecycleAdapter, name) == nil
      assert Lotus.Source.Supervisor.running?(name)

      LifecycleResolver.put_sources([])
      assert {:ok, %{stopped: [^name]}} = Lotus.Source.reconcile()
      assert_received {:source_stopped, ^name}
    end

    test "reports a source whose child fails to start and tries it again next time" do
      good = uniq("good")
      bad = uniq("bad")
      LifecycleResolver.put_sources([source(bad, %{children: :failing}), source(good)])

      assert {:ok, %{started: [^good], failed: [{^bad, reason}]}} = Lotus.Source.reconcile()
      assert {:shutdown, {:failed_to_start_child, :worker, :refused}} = reason
      refute Lotus.Source.Supervisor.running?(bad)
      refute_received {:source_started, ^bad}

      LifecycleResolver.put_sources([source(bad), source(good)])
      assert {:ok, %{started: [^bad], failed: []}} = Lotus.Source.reconcile()
      assert is_pid(Registry.whereis(LifecycleAdapter, bad))
    end

    test "a started hook that raises stops the children and counts as a failed start" do
      name = uniq("raising")
      LifecycleResolver.put_sources([source(name, %{started: :raise})])

      assert {:ok, %{started: [], failed: [{^name, %RuntimeError{}}]}} = Lotus.Source.reconcile()
      assert Registry.whereis(LifecycleAdapter, name) == nil
      refute Lotus.Source.Supervisor.running?(name)
    end

    test "starts a source again after its supervisor stopped" do
      name = uniq("crashed")
      LifecycleResolver.put_sources([source(name)])
      {:ok, _} = Lotus.Source.reconcile()
      assert_received {:source_started, ^name}

      {_, sup, _, _} =
        ChildSupervisor
        |> Supervisor.which_children()
        |> Enum.find(fn {id, _, _, _} -> id == {:source, LifecycleAdapter, name} end)

      Supervisor.stop(sup, :shutdown)
      refute MapSet.member?(ChildSupervisor.running_ids(), {:source, LifecycleAdapter, name})

      assert {:ok, %{started: [^name], stopped: [^name]}} = Lotus.Source.reconcile()
      assert is_pid(Registry.whereis(LifecycleAdapter, name))
    end

    test "returns an error and keeps the running sources when the resolver raises" do
      name = uniq("warehouse")
      LifecycleResolver.put_sources([source(name)])
      {:ok, _} = Lotus.Source.reconcile()
      pid = Registry.whereis(LifecycleAdapter, name)

      LifecycleResolver.put_sources(:raise)
      assert {:error, %RuntimeError{message: "resolver is not ready"}} = Lotus.Source.reconcile()

      assert Registry.whereis(LifecycleAdapter, name) == pid
      assert Lotus.Source.Supervisor.running?(name)
    end

    test "starts nothing for adapters without lifecycle callbacks" do
      LifecycleResolver.put_sources([Postgres.wrap("pg", Lotus.Test.Repo)])

      assert {:ok, %{started: ["pg"], stopped: [], failed: []}} = Lotus.Source.reconcile()
      assert ChildSupervisor.ids() == MapSet.new()
      assert Lotus.Source.Supervisor.running?("pg")
    end
  end

  describe "suspend/1 and resume/1" do
    test "keeps a suspended source stopped across reconciles until it is resumed" do
      name = uniq("idle")
      LifecycleResolver.put_sources([source(name)])
      {:ok, _} = Lotus.Source.reconcile()

      assert {:ok, %{stopped: [^name]}} = Lotus.Source.Supervisor.suspend(name)
      assert_received {:source_stopped, ^name}
      assert Registry.whereis(LifecycleAdapter, name) == nil

      assert {:ok, %{started: [], stopped: []}} = Lotus.Source.reconcile()
      assert Registry.whereis(LifecycleAdapter, name) == nil
      refute Lotus.Source.Supervisor.running?(name)

      assert {:ok, %{started: [^name]}} = Lotus.Source.Supervisor.resume(name)
      assert is_pid(Registry.whereis(LifecycleAdapter, name))
    end

    test "forgets a suspended name once the resolver drops it" do
      name = uniq("idle")
      LifecycleResolver.put_sources([source(name)])
      {:ok, _} = Lotus.Source.reconcile()
      {:ok, _} = Lotus.Source.Supervisor.suspend(name)

      LifecycleResolver.put_sources([])
      {:ok, _} = Lotus.Source.reconcile()

      LifecycleResolver.put_sources([source(name)])
      assert {:ok, %{started: [^name]}} = Lotus.Source.reconcile()
    end
  end
end
