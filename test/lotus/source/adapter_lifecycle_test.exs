defmodule Lotus.Source.AdapterLifecycleTest do
  use ExUnit.Case, async: true

  alias Lotus.Source.Adapter
  alias Lotus.Test.LifecycleAdapter
  alias Lotus.Test.NoOpAdapter

  describe "defaults for adapters without lifecycle callbacks" do
    setup do
      adapter = %Adapter{name: "plain", module: NoOpAdapter, state: :state, source_type: :other}
      {:ok, adapter: adapter}
    end

    test "shared_children/1 is empty" do
      assert Adapter.shared_children(NoOpAdapter) == []
    end

    test "source_children/1 is empty", %{adapter: adapter} do
      assert Adapter.source_children(adapter) == []
    end

    test "source_started/1 and source_stopped/1 are :ok", %{adapter: adapter} do
      assert Adapter.source_started(adapter) == :ok
      assert Adapter.source_stopped(adapter) == :ok
    end
  end

  describe "dispatch" do
    setup do
      {:ok, adapter: LifecycleAdapter.wrap("dispatch", %{owner: self()})}
    end

    test "shared_children/1 calls the module" do
      assert [%{id: :shared}] = Adapter.shared_children(LifecycleAdapter)
    end

    test "source_children/1 passes the name and state", %{adapter: adapter} do
      assert [%{id: :worker, start: {Agent, :start_link, [_fun, [name: name]]}}] =
               Adapter.source_children(adapter)

      assert name == Lotus.Source.Registry.via(LifecycleAdapter, "dispatch")
    end

    test "source_started/1 and source_stopped/1 pass the name and state", %{adapter: adapter} do
      assert :ok = Adapter.source_started(adapter)
      assert_received {:source_started, "dispatch"}

      assert :ok = Adapter.source_stopped(adapter)
      assert_received {:source_stopped, "dispatch"}
    end
  end
end
