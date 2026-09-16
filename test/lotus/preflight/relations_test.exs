defmodule Lotus.Preflight.RelationsTest do
  use ExUnit.Case, async: true
  alias Lotus.Preflight.Relations

  # The process-dictionary functions are deprecated. Calling them through
  # `apply/3` keeps the compiler from warning while they are still shipped.
  defp put(outcome), do: call(:put, [outcome])
  defp get, do: call(:get, [])
  defp take, do: call(:take, [])
  defp clear, do: call(:clear, [])
  defp call(name, args), do: apply(Relations, name, args)

  describe "put/1" do
    test "stores relations in process dictionary" do
      relations = [{"public", "users"}, {"public", "posts"}]

      assert :ok = put(relations)
      assert Process.get(:lotus_preflight_relations) == relations
    end

    test "overwrites existing relations" do
      old_relations = [{"public", "old_table"}]
      new_relations = [{"public", "new_table"}]

      put(old_relations)
      assert Process.get(:lotus_preflight_relations) == old_relations

      put(new_relations)
      assert Process.get(:lotus_preflight_relations) == new_relations
    end

    test "accepts empty list" do
      assert :ok = put([])
      assert Process.get(:lotus_preflight_relations) == []
    end

    test "stores an unrestricted outcome" do
      assert :ok = put({:unrestricted, "adapter cannot name its tables"})

      assert Process.get(:lotus_preflight_relations) ==
               {:unrestricted, "adapter cannot name its tables"}
    end
  end

  describe "to_list/1" do
    test "returns a relation list unchanged" do
      assert Relations.to_list([{"public", "users"}]) == [{"public", "users"}]
      assert Relations.to_list([]) == []
    end

    test "narrows an unrestricted outcome to no relations" do
      assert Relations.to_list({:unrestricted, "cannot name its tables"}) == []
    end
  end

  describe "get/0" do
    test "returns stored relations" do
      relations = [{"public", "users"}, {"reporting", "metrics"}]
      Process.put(:lotus_preflight_relations, relations)

      assert get() == relations
    end

    test "returns empty list when no relations stored" do
      Process.delete(:lotus_preflight_relations)
      assert get() == []
    end

    test "returns empty list when process dictionary has nil" do
      Process.put(:lotus_preflight_relations, nil)
      assert get() == []
    end
  end

  describe "take/0" do
    test "returns relations and clears them from process dictionary" do
      relations = [{"public", "users"}, {"public", "posts"}]
      Process.put(:lotus_preflight_relations, relations)

      assert take() == relations
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "returns empty list and clears when no relations stored" do
      Process.delete(:lotus_preflight_relations)

      assert take() == []
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "is idempotent - second call returns empty list" do
      relations = [{"public", "users"}]
      Process.put(:lotus_preflight_relations, relations)

      assert take() == relations
      assert take() == []
      assert take() == []
    end
  end

  describe "clear/0" do
    test "removes relations from process dictionary" do
      relations = [{"public", "users"}]
      Process.put(:lotus_preflight_relations, relations)

      assert :ok = clear()
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "is safe to call when no relations stored" do
      Process.delete(:lotus_preflight_relations)

      assert :ok = clear()
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "is idempotent" do
      Process.put(:lotus_preflight_relations, [{"public", "users"}])

      assert :ok = clear()
      assert :ok = clear()
      assert :ok = clear()
      assert Process.get(:lotus_preflight_relations) == nil
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:lotus_preflight_relations)
    end)
  end
end
