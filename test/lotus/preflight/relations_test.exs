defmodule Lotus.Preflight.RelationsTest do
  use ExUnit.Case, async: true
  alias Lotus.Preflight.Relations

  describe "to_list/1" do
    test "returns a relation list unchanged" do
      assert Relations.to_list([{"public", "users"}]) == [{"public", "users"}]
      assert Relations.to_list([]) == []
    end

    test "narrows an unrestricted outcome to no relations" do
      assert Relations.to_list({:unrestricted, "cannot name its tables"}) == []
    end

    test "narrows a skipped outcome to no relations" do
      assert Relations.to_list({:skipped, "not preflighted"}) == []
    end
  end

  test "the process-dictionary functions are gone in v2.0" do
    Code.ensure_loaded!(Relations)

    for {name, arity} <- [put: 1, get: 0, take: 0, clear: 0] do
      refute function_exported?(Relations, name, arity)
    end
  end
end
