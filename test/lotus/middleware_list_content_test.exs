defmodule Lotus.MiddlewareListContentTest do
  @moduledoc """
  A list or a get of queries and dashboards with `context:` fires
  `:list_content`, and reads what the plugs' query finds. Without
  `context:`, it does not fire.
  """

  use Lotus.Case

  import Ecto.Query

  alias Lotus.{Dashboards, Middleware, Storage}

  # The caller's own: an owner_id like theirs.
  defmodule OwnPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{query: query, context: %{user_id: id}} = payload, _opts) do
      send(self(), {:list_content, payload})
      {:cont, %{payload | query: where(query, [r], r.owner_id == ^id)}}
    end
  end

  defmodule HaltPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: {:halt, "no reading"}
  end

  defmodule NotAQueryPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(payload, _opts), do: {:cont, %{payload | query: :everything}}
  end

  defp plug!(plug) do
    Middleware.compile(%{list_content: [{plug, []}]})
    on_exit(fn -> :persistent_term.erase({Middleware, :compiled}) end)
  end

  setup do
    {:ok, ana} = Storage.create_query(%{name: "ana's", statement: "SELECT 1"}, owner_id: "ana")
    {:ok, ben} = Storage.create_query(%{name: "ben's", statement: "SELECT 2"}, owner_id: "ben")
    {:ok, board} = Dashboards.create_dashboard(%{name: "ana's board"}, owner_id: "ana")
    {:ok, other} = Dashboards.create_dashboard(%{name: "ben's board"}, owner_id: "ben")
    %{ana: ana, ben: ben, board: board, other: other}
  end

  describe "with context:" do
    setup do
      plug!(OwnPlug)
    end

    test "lists only what the plug's query finds", %{ana: ana, board: board} do
      as_ana = [context: %{user_id: "ana"}]

      assert Enum.map(Lotus.list_queries(as_ana), & &1.id) == [ana.id]
      assert Enum.map(Storage.list_queries_by([search: "'s"] ++ as_ana), & &1.id) == [ana.id]
      assert Enum.map(Lotus.list_dashboards(as_ana), & &1.id) == [board.id]

      assert Enum.map(Lotus.list_dashboards_by([search: "board"] ++ as_ana), & &1.id) == [
               board.id
             ]

      assert_received {:list_content, %{resource: :query, context: %{user_id: "ana"}, scope: nil}}
      assert_received {:list_content, %{resource: :dashboard}}
    end

    test "gets a record only when the plug's query finds it", %{
      ana: ana,
      ben: ben,
      board: board,
      other: other
    } do
      as_ana = [context: %{user_id: "ana"}]

      assert Lotus.get_query(ana.id, as_ana).id == ana.id
      assert Lotus.get_query(ben.id, as_ana) == nil
      assert_raise Ecto.NoResultsError, fn -> Lotus.get_query!(ben.id, as_ana) end

      assert Lotus.get_dashboard(board.id, as_ana).id == board.id
      assert Lotus.get_dashboard(other.id, as_ana) == nil
      assert_raise Ecto.NoResultsError, fn -> Lotus.get_dashboard!(other.id, as_ana) end
    end

    test "keeps the caller's own filters", %{ben: ben} do
      as_ben = [context: %{user_id: "ben"}]
      assert Storage.list_queries_by([owner_id: "ana"] ++ as_ben) == []
      assert Enum.map(Storage.list_queries_by([owner_id: "ben"] ++ as_ben), & &1.id) == [ben.id]
    end
  end

  test "without context:, the event does not fire and everything is read", %{ben: ben} do
    plug!(OwnPlug)

    assert length(Lotus.list_queries()) == 2
    assert Lotus.get_query(ben.id).id == ben.id
    assert length(Lotus.list_dashboards()) == 2
    refute_received {:list_content, _payload}
  end

  test "a halt reads nothing", %{ana: ana} do
    plug!(HaltPlug)

    assert Lotus.list_queries(context: nil) == []
    assert Lotus.get_query(ana.id, context: nil) == nil
    assert Lotus.list_dashboards(context: %{}) == []
  end

  test "a plug that continues with something other than a query is ignored" do
    plug!(NotAQueryPlug)
    assert length(Lotus.list_queries(context: %{})) == 2
  end
end
