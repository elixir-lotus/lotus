defmodule Lotus.Preflight.RelationsTest do
  use ExUnit.Case, async: true
  alias Lotus.Preflight.Relations

  describe "put/1" do
    test "stores relations in process dictionary" do
      relations = [{"public", "users"}, {"public", "posts"}]

      assert :ok = Relations.put(relations)
      assert Process.get(:lotus_preflight_relations) == relations
    end

    test "overwrites existing relations" do
      old_relations = [{"public", "old_table"}]
      new_relations = [{"public", "new_table"}]

      Relations.put(old_relations)
      assert Process.get(:lotus_preflight_relations) == old_relations

      Relations.put(new_relations)
      assert Process.get(:lotus_preflight_relations) == new_relations
    end

    test "accepts empty list" do
      assert :ok = Relations.put([])
      assert Process.get(:lotus_preflight_relations) == []
    end

    test "stores an unrestricted outcome" do
      assert :ok = Relations.put({:unrestricted, "adapter cannot name its tables"})

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

      assert Relations.get() == relations
    end

    test "returns empty list when no relations stored" do
      Process.delete(:lotus_preflight_relations)
      assert Relations.get() == []
    end

    test "returns empty list when process dictionary has nil" do
      Process.put(:lotus_preflight_relations, nil)
      assert Relations.get() == []
    end
  end

  describe "take/0" do
    test "returns relations and clears them from process dictionary" do
      relations = [{"public", "users"}, {"public", "posts"}]
      Process.put(:lotus_preflight_relations, relations)

      assert Relations.take() == relations
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "returns empty list and clears when no relations stored" do
      Process.delete(:lotus_preflight_relations)

      assert Relations.take() == []
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "is idempotent - second call returns empty list" do
      relations = [{"public", "users"}]
      Process.put(:lotus_preflight_relations, relations)

      assert Relations.take() == relations
      assert Relations.take() == []
      assert Relations.take() == []
    end
  end

  describe "clear/0" do
    test "removes relations from process dictionary" do
      relations = [{"public", "users"}]
      Process.put(:lotus_preflight_relations, relations)

      assert :ok = Relations.clear()
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "is safe to call when no relations stored" do
      Process.delete(:lotus_preflight_relations)

      assert :ok = Relations.clear()
      assert Process.get(:lotus_preflight_relations) == nil
    end

    test "is idempotent" do
      Process.put(:lotus_preflight_relations, [{"public", "users"}])

      assert :ok = Relations.clear()
      assert :ok = Relations.clear()
      assert :ok = Relations.clear()
      assert Process.get(:lotus_preflight_relations) == nil
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:lotus_preflight_relations)
    end)
  end
end
