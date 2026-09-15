defmodule Lotus.MiddlewareContentChangeTest do
  @moduledoc """
  Every content mutation takes `:context` and fires `:before_content_change`
  and `:after_content_change` with its operation and resource: queries,
  visualizations, dashboards, public sharing, cards and their order, filters
  and filter mappings, through the context modules and through the `Lotus`
  facade.

  A plug on `:before_content_change` can refuse a save, a delete, a reorder
  and the enabling of a share link.
  """

  use Lotus.Case

  import Lotus.Fixtures

  alias Lotus.{Dashboards, Middleware, Storage, Viz}

  alias Lotus.Storage.{
    Dashboard,
    DashboardCard,
    DashboardCardFilterMapping,
    DashboardFilter,
    Query,
    QueryVisualization
  }

  defmodule CapturePlug do
    @moduledoc false
    def init(event), do: event

    def call(payload, event) do
      send(self(), {event, payload})
      {:cont, payload}
    end
  end

  defmodule RefusePlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: {:halt, "viewers may not change content"}
  end

  defmodule RefuseSharingPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{op: :enable_sharing}, _opts), do: {:halt, "sharing is disabled"}
    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule RefuseCardPlug do
    @moduledoc false
    def init(card_id), do: card_id

    def call(%{resource: :dashboard_card, record: %{id: card_id}}, card_id),
      do: {:halt, "card is locked"}

    def call(payload, _card_id), do: {:cont, payload}
  end

  defmodule PositionsPlug do
    @moduledoc false
    import Ecto.Query

    alias Lotus.Storage.DashboardCard
    alias Lotus.Test.Repo

    def init(opts), do: opts

    def call(%{record: %DashboardCard{dashboard_id: dashboard_id}} = payload, _opts) do
      positions =
        from(c in DashboardCard,
          where: c.dashboard_id == ^dashboard_id,
          order_by: c.id,
          select: {c.id, c.position}
        )
        |> Repo.all()

      send(self(), {:positions_after, positions})
      {:cont, payload}
    end
  end

  @context %{user_id: 42}
  @missing_id 999_999

  setup do
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)
    :ok
  end

  defp capture_content_changes do
    Middleware.compile(%{
      before_content_change: [{CapturePlug, :before_content_change}],
      after_content_change: [{CapturePlug, :after_content_change}]
    })
  end

  defp refuse_content_changes do
    Middleware.compile(%{before_content_change: [{RefusePlug, []}]})
  end

  defp assert_content_change(op, resource) do
    assert_received {:before_content_change,
                     %{op: ^op, resource: ^resource, context: @context} = before_payload}

    assert_received {:after_content_change,
                     %{op: ^op, resource: ^resource, context: @context} = written_payload}

    {before_payload, written_payload}
  end

  defp refute_content_change do
    refute_received {:before_content_change, _payload}
    refute_received {:after_content_change, _payload}
  end

  describe "queries" do
    test "create, update and delete carry the context" do
      capture_content_changes()

      {:ok, query} =
        Storage.create_query(%{name: "Orders", statement: "SELECT 1"}, context: @context)

      assert_content_change(:create, :query)

      {:ok, query} = Storage.update_query(query, %{name: "All orders"}, context: @context)
      {_before, written} = assert_content_change(:update, :query)
      assert written.changes == %{name: "All orders"}

      {:ok, _query} = Storage.delete_query(query, context: @context)
      assert_content_change(:delete, :query)
    end

    test "the facade passes the context through" do
      capture_content_changes()

      {:ok, query} =
        Lotus.create_query(%{name: "Orders", statement: "SELECT 1"}, context: @context)

      assert_content_change(:create, :query)

      {:ok, query} = Lotus.update_query(query, %{name: "All orders"}, context: @context)
      assert_content_change(:update, :query)

      {:ok, _query} = Lotus.delete_query(query, context: @context)
      assert_content_change(:delete, :query)
    end

    test "the existing arities still write, with a nil context" do
      capture_content_changes()

      assert {:ok, query} = Lotus.create_query(%{name: "Orders", statement: "SELECT 1"})
      assert_received {:before_content_change, %{op: :create, context: nil}}

      assert {:ok, query} = Lotus.update_query(query, %{name: "All orders"})
      assert {:ok, _query} = Lotus.delete_query(query)
    end

    test "a plug refuses a save, an update and a delete" do
      query = query_fixture(%{name: "Orders"})
      refuse_content_changes()

      assert {:error, {:halted, "viewers may not change content"}} =
               Storage.create_query(%{name: "New", statement: "SELECT 1"}, context: @context)

      assert {:error, {:halted, "viewers may not change content"}} =
               Lotus.update_query(query, %{name: "Renamed"}, context: @context)

      assert {:error, {:halted, "viewers may not change content"}} =
               Lotus.delete_query(query, context: @context)

      assert [%Query{name: "Orders"}] = Storage.list_queries()
    end
  end

  describe "visualizations" do
    test "create by query or id, update, and delete by struct or id carry the context" do
      query = query_fixture()
      capture_content_changes()

      attrs = %{name: "Chart", position: 0, config: %{"chart" => "bar"}}

      {:ok, viz} = Viz.create_visualization(query, attrs, context: @context)
      assert_content_change(:create, :visualization)

      {:ok, by_id} =
        Lotus.create_visualization(query.id, %{attrs | name: "Table"}, context: @context)

      assert_content_change(:create, :visualization)

      {:ok, viz} = Lotus.update_visualization(viz, %{name: "Bar chart"}, context: @context)
      assert_content_change(:update, :visualization)

      {:ok, _viz} = Viz.delete_visualization(viz, context: @context)
      assert_content_change(:delete, :visualization)

      {:ok, %QueryVisualization{}} = Lotus.delete_visualization(by_id.id, context: @context)
      assert_content_change(:delete, :visualization)
    end

    test "deleting a missing id fires nothing" do
      capture_content_changes()

      assert {:error, :not_found} = Viz.delete_visualization(@missing_id, context: @context)
      refute_content_change()
    end
  end

  describe "dashboards" do
    test "create, update and delete carry the context" do
      capture_content_changes()

      {:ok, dashboard} = Lotus.create_dashboard(%{name: "Sales"}, context: @context)
      assert_content_change(:create, :dashboard)

      {:ok, dashboard} =
        Dashboards.update_dashboard(dashboard, %{name: "Revenue"}, context: @context)

      assert_content_change(:update, :dashboard)

      {:ok, _dashboard} = Lotus.delete_dashboard(dashboard, context: @context)
      assert_content_change(:delete, :dashboard)
    end

    test "a plug refuses a delete" do
      dashboard = dashboard_fixture()
      refuse_content_changes()

      assert {:error, {:halted, _reason}} = Lotus.delete_dashboard(dashboard, context: @context)
      assert %Dashboard{} = Dashboards.get_dashboard(dashboard.id)
    end
  end

  describe "public sharing" do
    test "enabling is :enable_sharing, and the stored record tells a first enable from a rotation" do
      dashboard = dashboard_fixture()
      capture_content_changes()

      {:ok, shared} = Lotus.enable_public_sharing(dashboard, context: @context)
      {before_payload, written} = assert_content_change(:enable_sharing, :dashboard)

      assert %Dashboard{public_token: nil} = before_payload.record
      assert %{public_token: token} = before_payload.changeset.changes
      assert is_binary(token)
      assert written.changes == %{public_token: shared.public_token}

      {:ok, _rotated} = Dashboards.enable_public_sharing(shared, context: @context)
      {before_payload, _written} = assert_content_change(:enable_sharing, :dashboard)
      assert before_payload.record.public_token == shared.public_token
    end

    test "disabling is :disable_sharing, and disabling an unshared dashboard fires no after event" do
      {:ok, shared} = Lotus.enable_public_sharing(dashboard_fixture())
      capture_content_changes()

      {:ok, unshared} = Dashboards.disable_public_sharing(shared, context: @context)
      {_before, written} = assert_content_change(:disable_sharing, :dashboard)
      assert written.changes == %{public_token: nil}

      {:ok, _unshared} = Lotus.disable_public_sharing(unshared, context: @context)
      assert_received {:before_content_change, %{op: :disable_sharing}}
      refute_received {:after_content_change, _payload}
    end

    test "setting :public_token through update_dashboard is an :update a plug still sees" do
      dashboard = dashboard_fixture()
      capture_content_changes()

      {:ok, _dashboard} =
        Lotus.update_dashboard(dashboard, %{public_token: "chosen-token"}, context: @context)

      {before_payload, _written} = assert_content_change(:update, :dashboard)
      assert before_payload.changeset.changes == %{public_token: "chosen-token"}
    end

    test "a plug refuses the enabling of a share link and lets other updates through" do
      dashboard = dashboard_fixture(%{name: "Sales"})
      Middleware.compile(%{before_content_change: [{RefuseSharingPlug, []}]})

      assert {:error, {:halted, "sharing is disabled"}} =
               Lotus.enable_public_sharing(dashboard, context: @context)

      assert %Dashboard{public_token: nil} = Dashboards.get_dashboard!(dashboard.id)

      assert {:ok, %Dashboard{name: "Revenue"}} =
               Lotus.update_dashboard(dashboard, %{name: "Revenue"}, context: @context)
    end
  end

  describe "dashboard cards" do
    test "create by dashboard or id, update, and delete by struct or id carry the context" do
      dashboard = dashboard_fixture()
      capture_content_changes()

      attrs = %{card_type: :text, position: 0, content: %{"text" => "Hello"}}

      {:ok, card} = Dashboards.create_dashboard_card(dashboard, attrs, context: @context)
      assert_content_change(:create, :dashboard_card)

      {:ok, by_id} = Lotus.create_dashboard_card(dashboard.id, attrs, context: @context)
      assert_content_change(:create, :dashboard_card)

      {:ok, card} = Lotus.update_dashboard_card(card, %{title: "Greeting"}, context: @context)
      assert_content_change(:update, :dashboard_card)

      {:ok, _card} = Dashboards.delete_dashboard_card(card, context: @context)
      assert_content_change(:delete, :dashboard_card)

      {:ok, %DashboardCard{}} = Lotus.delete_dashboard_card(by_id.id, context: @context)
      assert_content_change(:delete, :dashboard_card)
    end

    test "deleting a missing id fires nothing" do
      capture_content_changes()

      assert {:error, :not_found} =
               Dashboards.delete_dashboard_card(@missing_id, context: @context)

      refute_content_change()
    end
  end

  describe "reordering dashboard cards" do
    setup do
      dashboard = dashboard_fixture()

      [c1, c2, c3] =
        for position <- 0..2, do: dashboard_card_fixture(dashboard, %{position: position})

      %{dashboard: dashboard, c1: c1, c2: c2, c3: c3}
    end

    test "each moved card is an :update of its position with the context; unmoved cards fire nothing",
         %{dashboard: dashboard, c1: c1, c2: c2, c3: c3} do
      capture_content_changes()

      assert :ok =
               Lotus.reorder_dashboard_cards(dashboard, [c1.id, c3.id, c2.id], context: @context)

      {before_c3, _written} = assert_content_change(:update, :dashboard_card)
      {before_c2, _written} = assert_content_change(:update, :dashboard_card)
      refute_content_change()

      moved =
        Map.new([before_c3, before_c2], &{&1.record.id, &1.changeset.changes})

      assert moved == %{c3.id => %{position: 1}, c2.id => %{position: 2}}

      assert Enum.map(Dashboards.list_dashboard_cards(dashboard), & &1.id) ==
               [c1.id, c3.id, c2.id]
    end

    test "after events fire once every position is written",
         %{dashboard: dashboard, c1: c1, c2: c2, c3: c3} do
      Middleware.compile(%{after_content_change: [{PositionsPlug, []}]})

      assert :ok = Dashboards.reorder_dashboard_cards(dashboard.id, [c3.id, c1.id, c2.id])

      final = [{c1.id, 1}, {c2.id, 2}, {c3.id, 0}]

      for _moved_card <- 1..3 do
        assert_received {:positions_after, ^final}
      end
    end

    test "a refusal on any card leaves every position as it was",
         %{dashboard: dashboard, c1: c1, c2: c2, c3: c3} do
      Middleware.compile(%{before_content_change: [{RefuseCardPlug, c1.id}]})

      assert {:error, {:halted, "card is locked"}} =
               Dashboards.reorder_dashboard_cards(dashboard, [c3.id, c2.id, c1.id],
                 context: @context
               )

      assert Enum.map(Dashboards.list_dashboard_cards(dashboard), &{&1.id, &1.position}) ==
               [{c1.id, 0}, {c2.id, 1}, {c3.id, 2}]
    end

    test "ids given as strings and ids of other dashboards' cards are handled as before",
         %{dashboard: dashboard, c1: c1, c2: c2, c3: c3} do
      other = dashboard_card_fixture(dashboard_fixture(), %{position: 5})
      capture_content_changes()

      ids = [to_string(c3.id), other.id, c2.id, c1.id]
      assert :ok = Dashboards.reorder_dashboard_cards(dashboard, ids)

      assert Enum.map(Dashboards.list_dashboard_cards(dashboard), &{&1.id, &1.position}) ==
               [{c3.id, 0}, {c2.id, 2}, {c1.id, 3}]

      assert %DashboardCard{position: 5} = Dashboards.get_dashboard_card(other.id)
    end
  end

  describe "dashboard filters" do
    test "create by dashboard or id, update, and delete by struct or id carry the context" do
      dashboard = dashboard_fixture()
      capture_content_changes()

      attrs = %{name: "region", label: "Region", filter_type: :text, widget: :input, position: 0}

      {:ok, filter} = Dashboards.create_dashboard_filter(dashboard, attrs, context: @context)
      assert_content_change(:create, :dashboard_filter)

      {:ok, by_id} =
        Lotus.create_dashboard_filter(dashboard.id, %{attrs | name: "country"}, context: @context)

      assert_content_change(:create, :dashboard_filter)

      {:ok, filter} =
        Lotus.update_dashboard_filter(filter, %{label: "Sales region"}, context: @context)

      assert_content_change(:update, :dashboard_filter)

      {:ok, _filter} = Dashboards.delete_dashboard_filter(filter, context: @context)
      assert_content_change(:delete, :dashboard_filter)

      {:ok, %DashboardFilter{}} = Lotus.delete_dashboard_filter(by_id.id, context: @context)
      assert_content_change(:delete, :dashboard_filter)
    end

    test "deleting a missing id fires nothing" do
      capture_content_changes()

      assert {:error, :not_found} =
               Dashboards.delete_dashboard_filter(@missing_id, context: @context)

      refute_content_change()
    end

    test "a filter rejected by the dependency check writes nothing and fires no after event" do
      dashboard = dashboard_fixture()
      filter_on_other_dashboard = dashboard_filter_fixture(dashboard_fixture())
      query = query_fixture()
      capture_content_changes()

      attrs = %{
        name: "city",
        label: "City",
        filter_type: :select,
        widget: :select,
        position: 0,
        source_query_id: query.id,
        depends_on_filter_id: filter_on_other_dashboard.id
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               Dashboards.create_dashboard_filter(dashboard, attrs, context: @context)

      assert %{depends_on_filter_id: ["must be a filter of the same dashboard"]} =
               errors_on(changeset)

      refute_received {:after_content_change, _payload}
      assert [] == Dashboards.list_dashboard_filters(dashboard)
    end
  end

  describe "filter mappings" do
    setup do
      dashboard = dashboard_fixture()
      query = query_fixture()

      %{
        card: dashboard_card_fixture(dashboard, %{card_type: :query, query_id: query.id}),
        filter: dashboard_filter_fixture(dashboard)
      }
    end

    test "create keeps :transform beside :context, and delete by struct or id carries the context",
         %{card: card, filter: filter} do
      capture_content_changes()
      transform = %{"type" => "date_range_start"}

      {:ok, mapping} =
        Lotus.create_filter_mapping(card, filter, "start_date",
          transform: transform,
          context: @context
        )

      assert mapping.transform == transform
      assert_content_change(:create, :filter_mapping)

      {:ok, by_id} =
        Dashboards.create_filter_mapping(card.id, filter.id, "end_date", context: @context)

      assert_content_change(:create, :filter_mapping)

      {:ok, _mapping} = Dashboards.delete_filter_mapping(mapping, context: @context)
      assert_content_change(:delete, :filter_mapping)

      {:ok, %DashboardCardFilterMapping{}} =
        Lotus.delete_filter_mapping(by_id.id, context: @context)

      assert_content_change(:delete, :filter_mapping)
    end

    test "deleting a missing id fires nothing" do
      capture_content_changes()

      assert {:error, :not_found} =
               Dashboards.delete_filter_mapping(@missing_id, context: @context)

      refute_content_change()
    end
  end
end
