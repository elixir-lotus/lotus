defmodule Lotus.MiddlewareColumnSourcesTest do
  @moduledoc """
  `:after_query` carries, under `:column_sources`, where each result column
  comes from, so a plug with column rules of its own can apply each
  column's rule from its own relation, as Lotus applies its column policies.
  """

  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Cache.ETS
  alias Lotus.{Config, Fixtures, Middleware, Result, Runner}
  alias Lotus.Query.{Filter, Sort, Statement}
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.Repo

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:after_query, payload})
      {:cont, payload}
    end
  end

  @users {"public", "test_users"}
  @posts {"public", "test_posts"}
  @join "FROM test_users u JOIN test_posts p ON p.user_id = u.id"

  setup do
    clear_cache_tables()

    on_exit(fn ->
      :persistent_term.erase({Lotus.Middleware, :compiled})
      clear_cache_tables()
    end)

    Middleware.compile(%{after_query: [{CapturePlug, []}]})
    Fixtures.setup_test_data()
    :ok
  end

  defp clear_cache_tables do
    for table <- [:lotus_cache, :lotus_cache_tags] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  defp rules(column_rules) do
    stub(Config, :visibility_for_source_name, fn _source -> %{column: column_rules} end)
    :ok
  end

  defp run(sql, opts \\ []), do: Lotus.run_statement(sql, [], [repo: "postgres"] ++ opts)

  defp sources do
    assert_received {:after_query, %{column_sources: sources, result: %Result{columns: columns}}}
    assert length(sources) == length(columns)
    sources
  end

  describe "the sources of a statement's result columns" do
    test "name each qualified column's own relation, with no column rule configured" do
      assert {:ok, %Result{columns: ["name", "title", "id", "n"]}} =
               run("SELECT u.name, p.title, p.id AS id, upper(u.name) AS n #{@join}")

      assert sources() == [
               {:relation, @users},
               {:relation, @posts},
               {:relation, @posts},
               :unresolved
             ]
    end

    test "are :unresolved for an unqualified name over a join" do
      assert {:ok, _} = run("SELECT title, name #{@join}")
      assert sources() == [:unresolved, :unresolved]
    end

    test "name the one relation of a single-table statement only when qualified" do
      assert {:ok, _} = run("SELECT test_users.name, email FROM test_users")
      assert sources() == [{:relation, @users}, :unresolved]
    end

    test "are :unresolved at and after *" do
      assert {:ok, %Result{columns: columns}} = run("SELECT u.name, * #{@join}")
      assert [{:relation, @users} | rest] = sources()
      assert length(rest) == length(columns) - 1
      assert Enum.all?(rest, &(&1 == :unresolved))
    end

    test "are :unresolved for every column of a set operation" do
      assert {:ok, _} =
               run("SELECT u.name FROM test_users u UNION SELECT p.title FROM test_posts p")

      assert sources() == [:unresolved]
    end

    test "are the statement's own through the window, filter and sort wrappers" do
      sql = "SELECT u.name, p.title, upper(p.title) AS t #{@join}"
      expected = [{:relation, @users}, {:relation, @posts}, :unresolved]

      assert {:ok, _} = run(sql, window: [limit: 5])
      assert sources() == expected

      assert {:ok, _} =
               run(sql,
                 window: [limit: 5, offset: 0, count: :exact],
                 filters: [Filter.new("title", :neq, "nope")],
                 sorts: [Sort.new("name", :desc)]
               )

      assert sources() == expected
    end

    test "follow the columns a column policy omits" do
      rules([{"test_users", "email", :omit}])

      assert {:ok, %Result{columns: ["title", "name"]}} =
               run("SELECT p.title, u.email, u.name #{@join}")

      assert sources() == [{:relation, @posts}, {:relation, @users}]
    end

    test "are the ones the column policies applied by" do
      rules([{"test_users", "inserted_at", [action: :mask, mask: {:fixed, "X"}]}])

      assert {:ok, %Result{rows: rows}} = run("SELECT p.inserted_at, u.inserted_at #{@join}")
      assert Enum.all?(rows, fn [posted, joined] -> posted != "X" and joined == "X" end)
      assert sources() == [{:relation, @posts}, {:relation, @users}]
    end
  end

  describe "a paged run over two tables that both have ssn" do
    @ssn_join "FROM cs_users u JOIN cs_orders o ON o.user_id = u.id"

    setup do
      Repo.query!("CREATE TABLE cs_users (id integer, ssn text)")
      Repo.query!("CREATE TABLE cs_orders (id integer, user_id integer, ssn text)")
      Repo.query!("INSERT INTO cs_users (id, ssn) VALUES (1, 'user-ssn'), (2, 'user-ssn-2')")

      Repo.query!(
        "INSERT INTO cs_orders (id, user_id, ssn) VALUES (7, 1, 'order-ssn'), (8, 2, 'order-ssn-2')"
      )

      rules([
        {"cs_orders", "ssn", :allow},
        {"cs_users", "ssn", [action: :mask, mask: {:fixed, "X"}]}
      ])
    end

    @cs_users {"public", "cs_users"}
    @cs_orders {"public", "cs_orders"}

    test "a windowed run masks only the column of the table that masks it" do
      assert {:ok, %Result{columns: ["ssn", "ssn"], rows: rows}} =
               run("SELECT u.ssn, o.ssn #{@ssn_join} ORDER BY o.id", window: [limit: 10])

      assert rows == [["X", "order-ssn"], ["X", "order-ssn-2"]]
      assert sources() == [{:relation, @cs_users}, {:relation, @cs_orders}]
    end

    test "a filtered, sorted, windowed run masks only that column too" do
      assert {:ok, %Result{columns: ["id", "ssn", "ssn"], rows: rows}} =
               run("SELECT o.id AS id, u.ssn, o.ssn #{@ssn_join}",
                 window: [limit: 10, offset: 0, count: :exact],
                 filters: [Filter.new("id", :gte, 7)],
                 sorts: [Sort.new("id", :desc)]
               )

      assert rows == [[8, "X", "order-ssn-2"], [7, "X", "order-ssn"]]

      assert sources() == [
               {:relation, @cs_orders},
               {:relation, @cs_users},
               {:relation, @cs_orders}
             ]
    end

    test "a column the wrapped statement can't trace still gets the strictest policy" do
      assert {:ok, %Result{columns: columns, rows: [row | _]}} =
               run("SELECT * #{@ssn_join}", window: [limit: 10])

      assert for({"ssn", i} <- Enum.with_index(columns), do: Enum.at(row, i)) == ["X", "X"]

      assert Enum.all?(sources(), &(&1 == :unresolved))
    end
  end

  describe "on a cache hit" do
    setup do
      Config
      |> stub(:cache_adapter, fn -> {:ok, ETS} end)
      |> stub(:cache_namespace, fn -> "column_sources_test" end)
      |> stub(:default_cache_profile, fn -> :results end)
      |> stub(:cache_profile_settings, fn _profile -> [ttl_ms: 30_000] end)

      :ok
    end

    test "the sources are stored with the result and handed to :after_query" do
      sql = "SELECT u.name, p.title, upper(p.title) AS t #{@join}"
      expected = [{:relation, @users}, {:relation, @posts}, :unresolved]

      assert {:ok, _} = run(sql)
      assert_received {:after_query, %{origin: :executed, column_sources: ^expected}}

      assert {:ok, _} = run(sql)
      assert_received {:after_query, %{origin: :cached, column_sources: ^expected}}
    end
  end

  describe "a stream" do
    test "hands each chunk's sources to :after_query" do
      assert {:ok, rows} =
               Lotus.stream_statement(
                 "SELECT u.name, p.title #{@join} LIMIT 2",
                 [],
                 [repo: "postgres", chunk_size: 1],
                 fn chunks -> Enum.flat_map(chunks, & &1.rows) end
               )

      assert length(rows) == 2

      chunks = collect_chunks([])
      assert length(chunks) >= 2

      assert Enum.all?(chunks, &(&1 == [{:relation, @users}, {:relation, @posts}]))
    end
  end

  defp collect_chunks(acc) do
    receive do
      {:after_query, %{origin: :streamed, column_sources: sources}} ->
        collect_chunks([sources | acc])
    after
      0 -> acc
    end
  end

  describe "an outcome without sources that match the result" do
    setup do
      adapter = EctoAdapter.wrap("postgres", Repo)
      statement = %Statement{adapter: adapter.module, body: "SELECT 1", params: []}
      result = Result.new(["a", "b"], [[1, 2]])

      outcome = %{
        statement: statement,
        result: result,
        relations: [@users, @posts],
        origin: :cached
      }

      %{adapter: adapter, outcome: outcome}
    end

    test "has every column :unresolved when it carries none", %{adapter: a, outcome: outcome} do
      assert {:ok, _} = Runner.after_query(a, outcome)
      assert sources() == [:unresolved, :unresolved]
    end

    test "has every column :unresolved when its list is of another length",
         %{adapter: a, outcome: outcome} do
      outcome = Map.put(outcome, :column_sources, [{:relation, @users}])
      assert {:ok, _} = Runner.after_query(a, outcome)
      assert sources() == [:unresolved, :unresolved]
    end
  end
end
