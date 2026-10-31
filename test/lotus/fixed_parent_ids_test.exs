defmodule Lotus.FixedParentIdsTest do
  # A card or a filter stays on its dashboard, a visualization on its query,
  # and a filter mapping links a card and a filter of one dashboard.
  use Lotus.Case, async: true

  import Lotus.Fixtures

  alias Lotus.Dashboards

  setup do
    query = query_fixture()
    other_query = query_fixture(%{name: "Other"})
    dashboard = dashboard_fixture()
    other = dashboard_fixture(%{name: "Other dashboard"})

    %{query: query, other_query: other_query, dashboard: dashboard, other: other}
  end

  test "a card stays on its dashboard", %{dashboard: dashboard, other: other} do
    card = dashboard_card_fixture(dashboard)

    assert {:ok, updated} =
             Dashboards.update_dashboard_card(card, %{dashboard_id: other.id, title: "Moved?"})

    assert updated.dashboard_id == dashboard.id
    assert updated.title == "Moved?"
  end

  test "a filter stays on its dashboard", %{dashboard: dashboard, other: other} do
    filter = dashboard_filter_fixture(dashboard)

    assert {:ok, updated} =
             Dashboards.update_dashboard_filter(filter, %{dashboard_id: other.id, label: "Moved?"})

    assert updated.dashboard_id == dashboard.id
    assert updated.label == "Moved?"
  end

  test "a visualization stays on its query", %{query: query, other_query: other_query} do
    viz = visualization_fixture(query)

    assert {:ok, updated} =
             Lotus.update_visualization(viz, %{query_id: other_query.id, name: "Moved?"})

    assert updated.query_id == query.id
    assert updated.name == "Moved?"
  end

  test "a filter mapping links a card and a filter of one dashboard", %{
    dashboard: dashboard,
    other: other
  } do
    card = dashboard_card_fixture(dashboard)
    own_filter = dashboard_filter_fixture(dashboard)
    other_filter = dashboard_filter_fixture(other)

    assert {:ok, _mapping} = Dashboards.create_filter_mapping(card, own_filter, "region")

    assert {:error,
            %Ecto.Changeset{errors: [filter_id: {"must be a filter of the card's dashboard", _}]}} =
             Dashboards.create_filter_mapping(card, other_filter, "region")
  end
end
