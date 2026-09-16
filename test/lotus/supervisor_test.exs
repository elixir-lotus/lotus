defmodule Lotus.SupervisorTest do
  use ExUnit.Case, async: true

  import Cachex.Spec

  # Exercise init/1 directly so we can inspect the generated child list without
  # clashing with the application-level Lotus.Supervisor already running under
  # singleton names in the test environment.

  describe "init/1 — cache adapter child list" do
    test "returns a single ETS child when ETS is the configured adapter" do
      opts = [
        supervisor_name: :"lotus_sup_ets_#{System.unique_integer([:positive])}",
        cache: %{adapter: Lotus.Cache.ETS}
      ]

      {:ok, {_flags, children}} = Lotus.Supervisor.init(opts)

      ets_children =
        Enum.filter(children, fn child ->
          Supervisor.child_spec(child, []).id == Lotus.Cache.ETS
        end)

      assert length(ets_children) == 1
    end

    test "does not crash with FunctionClauseError when Cachex adapter returns child-spec maps" do
      opts = [
        supervisor_name: :"lotus_sup_cachex_#{System.unique_integer([:positive])}",
        cache: %{
          adapter: Lotus.Cache.Cachex,
          cachex_opts: [router: router(module: Cachex.Router.Local)]
        }
      ]

      {:ok, {_flags, children}} = Lotus.Supervisor.init(opts)

      child_ids = Enum.map(children, fn child -> Supervisor.child_spec(child, []).id end)

      assert {Cachex, :lotus_cache} in child_ids
      assert {Cachex, :lotus_cache_tags} in child_ids
    end

    test "does not start ETS next to the Cachex adapter, which owns the same table names" do
      opts = [
        supervisor_name: :"lotus_sup_cachex_only_#{System.unique_integer([:positive])}",
        cache: %{
          adapter: Lotus.Cache.Cachex,
          cachex_opts: [router: router(module: Cachex.Router.Local)]
        }
      ]

      {:ok, {_flags, children}} = Lotus.Supervisor.init(opts)

      child_ids = Enum.map(children, fn child -> Supervisor.child_spec(child, []).id end)

      refute Lotus.Cache.ETS in child_ids
    end

    test "starts the cluster channel first and the relay after the cache" do
      opts = [
        supervisor_name: :"lotus_sup_cluster_#{System.unique_integer([:positive])}",
        cache: %{adapter: Lotus.Cache.ETS}
      ]

      {:ok, {_flags, children}} = Lotus.Supervisor.init(opts)

      child_ids = Enum.map(children, fn child -> Supervisor.child_spec(child, []).id end)

      assert List.first(child_ids) == Lotus.Notifier

      cache_index = Enum.find_index(child_ids, &(&1 == Lotus.Cache.ETS))
      relay_index = Enum.find_index(child_ids, &(&1 == Lotus.Cache.Relay))

      assert relay_index > cache_index
    end

    test "starts ETS when no cache config is provided" do
      opts = [
        supervisor_name: :"lotus_sup_nil_#{System.unique_integer([:positive])}",
        cache: nil
      ]

      {:ok, {_flags, children}} = Lotus.Supervisor.init(opts)

      child_ids = Enum.map(children, fn child -> Supervisor.child_spec(child, []).id end)

      assert Lotus.Cache.ETS in child_ids
    end

    test "starts the source supervisor after the cache" do
      opts = [
        supervisor_name: :"lotus_sup_sources_#{System.unique_integer([:positive])}",
        cache: nil
      ]

      {:ok, {_flags, children}} = Lotus.Supervisor.init(opts)

      child_ids = Enum.map(children, fn child -> Supervisor.child_spec(child, []).id end)

      assert List.last(child_ids) == Lotus.Source.Supervisor
    end
  end
end
