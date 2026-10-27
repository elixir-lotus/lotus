defmodule Lotus.PinsTest do
  use Lotus.Case

  import Lotus.Fixtures

  alias Lotus.Storage.Pin

  defp result do
    %Lotus.Result{
      columns: ["id", "at", "total"],
      rows: [[1, ~D[2026-01-04], Decimal.new("12.50")], [2, nil, Decimal.new("3")]],
      num_rows: 2,
      duration_ms: 7,
      meta: %{total_count: 847}
    }
  end

  test "pins a result: its rows as text, its counts and the statement" do
    query = query_fixture()

    assert {:ok, %Pin{} = pin} =
             Lotus.pin_result(
               result(),
               %{query_id: query.id, statement: "SELECT 1", text: "SELECT 1;", vars: %{min: 3}},
               owner_id: 42
             )

    assert pin.owner_id == "42"
    assert pin.vars == %{"min" => 3}

    pin = Lotus.get_pin(query.id, owner_id: "42")

    assert pin.result == %{
             "columns" => ["id", "at", "total"],
             "rows" => [["1", "2026-01-04", "12.50"], ["2", nil, "3"]],
             "num_rows" => 2,
             "total_count" => 847,
             "duration_ms" => 7
           }

    assert pin.statement == "SELECT 1"
    assert pin.text == "SELECT 1;"
  end

  test "one pin per person and query: pinning again replaces it" do
    query = query_fixture()
    {:ok, _} = Lotus.pin_result(result(), %{query_id: query.id, statement: "A"}, owner_id: "1")
    {:ok, _} = Lotus.pin_result(result(), %{query_id: query.id, statement: "B"}, owner_id: "1")
    {:ok, _} = Lotus.pin_result(result(), %{query_id: query.id, statement: "C"}, owner_id: "2")
    {:ok, _} = Lotus.pin_result(result(), %{query_id: nil, statement: "D"}, owner_id: "1")

    assert Lotus.get_pin(query.id, owner_id: "1").statement == "B"
    assert Lotus.get_pin(query.id, owner_id: "2").statement == "C"
    assert Lotus.get_pin(nil, owner_id: "1").statement == "D"
    assert Lotus.get_pin(query.id) == nil
    assert Repo.aggregate(Pin, :count) == 3
  end

  test "unpin, and a deleted query takes its pins" do
    query = query_fixture()
    {:ok, _} = Lotus.pin_result(result(), %{query_id: query.id, statement: "A"}, owner_id: "1")
    {:ok, _} = Lotus.pin_result(result(), %{query_id: nil, statement: "B"}, owner_id: "1")

    assert :ok = Lotus.unpin(nil, owner_id: "1")
    assert Lotus.get_pin(nil, owner_id: "1") == nil

    {:ok, _} = Lotus.delete_query(query)
    assert Lotus.get_pin(query.id, owner_id: "1") == nil
  end

  test "a tenant's pins are its own" do
    {:ok, _} = Lotus.pin_result(result(), %{statement: "A"}, owner_id: "1", tenant_id: "t1")
    assert Lotus.get_pin(nil, owner_id: "1", tenant_id: "t2") == nil
    assert Lotus.get_pin(nil, owner_id: "1", tenant_id: "t1").statement == "A"
  end

  test "a statement is needed" do
    assert {:error, %Ecto.Changeset{}} = Lotus.pin_result(result(), %{statement: nil})
  end
end
