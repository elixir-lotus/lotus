defmodule Lotus.StreamTest do
  @moduledoc """
  `Lotus.stream_statement/4`, `Lotus.stream_query/3` and
  `Lotus.Export.stream/4` hand a statement's rows to a function chunk by
  chunk: through the same checks as a run, with the column policies and
  `:after_query` applied to every chunk, and read from the source as they are
  consumed by an adapter that declares `Lotus.Source.Adapter.Streaming`.
  """

  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Middleware, Result}
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Storage.Query
  alias Lotus.Test.{InMemoryAdapter, SqliteRepo}

  @series "SELECT n FROM generate_series(1, 2500) AS s(n)"

  defmodule UpcasePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{origin: :streamed, result: result} = payload, _opts) do
      send(self(), {:after_query, length(result.rows)})
      rows = Enum.map(result.rows, fn [n] -> [n * 10] end)
      {:cont, %{payload | result: %{result | rows: rows}}}
    end
  end

  defmodule RefusePlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, reason), do: {:halt, reason}
  end

  defmodule SecondChunkPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{result: %{rows: [[1001] | _]}}, _opts), do: {:halt, "no more"}
    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule SessionPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement} = payload, _opts),
      do: {:cont, %{payload | statement: %{statement | session: %{"app.tenant_id" => "acme"}}}}
  end

  setup do
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)
    :ok
  end

  defp sizes(chunks), do: Enum.map(chunks, &length(&1.rows))

  describe "on PostgreSQL" do
    test "the rows come in chunks of :chunk_size, each a result with the columns" do
      assert {:ok, chunks} =
               Lotus.stream_statement(@series, [], [chunk_size: 1000], &Enum.to_list/1)

      assert sizes(chunks) == [1000, 1000, 500]
      assert Enum.all?(chunks, &match?(%Result{columns: ["n"]}, &1))
      assert chunks |> Enum.flat_map(& &1.rows) |> List.last() == [2500]
    end

    test "fun's value is returned" do
      assert {:ok, 2500} =
               Lotus.stream_statement(@series, [], [], fn chunks ->
                 Enum.reduce(chunks, 0, &(&2 + length(&1.rows)))
               end)
    end

    test "an empty result is one chunk with the columns and no rows" do
      sql = "SELECT n FROM generate_series(1, 0) AS s(n)"

      assert {:ok, [%Result{columns: ["n"], rows: []}]} =
               Lotus.stream_statement(sql, [], [], &Enum.to_list/1)
    end

    test "the built-in Postgres and MySQL adapters stream; others don't" do
      for {name, repo} <- [{"postgres", Lotus.Test.Repo}, {"mysql", Lotus.Test.MysqlRepo}] do
        assert Adapter.capability?(EctoAdapter.wrap(name, repo), :streaming)
      end

      # The SQLite driver doesn't name the columns of the rows it streams.
      refute Adapter.capability?(EctoAdapter.wrap("sqlite", Lotus.Test.SqliteRepo), :streaming)

      refute Adapter.capability?(
               InMemoryAdapter.adapter("mem", InMemoryAdapter.dataset()),
               :streaming
             )
    end

    test "every chunk passes through :after_query with origin :streamed" do
      Middleware.compile(%{after_query: [{UpcasePlug, []}]})

      assert {:ok, chunks} =
               Lotus.stream_statement(@series, [], [chunk_size: 1000], &Enum.to_list/1)

      assert_received {:after_query, 1000}
      assert_received {:after_query, 1000}
      assert_received {:after_query, 500}
      assert chunks |> Enum.flat_map(& &1.rows) |> List.last() == [25_000]
    end

    test "a refusal before the first row returns it, and fun is not called" do
      Middleware.compile(%{before_query: [{RefusePlug, "denied"}]})

      assert {:error, "denied"} =
               Lotus.stream_statement(@series, [], [], fn _ -> flunk("fun ran") end)

      Middleware.compile(%{before_execute: [{RefusePlug, "gated"}]})

      assert {:error, "gated"} =
               Lotus.stream_statement(@series, [], [], fn _ -> flunk("fun ran") end)
    end

    test "a refusal of a chunk stops the stream and returns it" do
      Middleware.compile(%{after_query: [{SecondChunkPlug, []}]})

      assert {:error, "no more"} =
               Lotus.stream_statement(@series, [], [chunk_size: 1000], fn chunks ->
                 Enum.each(chunks, fn chunk -> send(self(), {:chunk, length(chunk.rows)}) end)
               end)

      assert_received {:chunk, 1000}
      refute_received {:chunk, _}
    end

    test "a write is refused as in a run" do
      assert {:error, message} =
               Lotus.stream_statement("DELETE FROM test_users", [], [], &Enum.to_list/1)

      assert message =~ ~r/read-only|not allowed|write/i
    end

    test "the statement's session settings apply to the stream" do
      Middleware.compile(%{before_query: [{SessionPlug, []}]})

      assert {:ok, [%Result{rows: [["acme"]]}]} =
               Lotus.stream_statement(
                 "SELECT current_setting('app.tenant_id', true)",
                 [],
                 [],
                 &Enum.to_list/1
               )
    end

    test "run and query telemetry bracket the stream, with the rows streamed" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :run, :stop], [:lotus, :query, :stop]],
        fn event, measurements, metadata, _ -> send(pid, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      assert {:ok, _} = Lotus.stream_statement(@series, [], [], &Stream.run/1)

      assert_received {[:lotus, :run, :stop], %{row_count: 2500},
                       %{
                         origin: :streamed,
                         result: %Result{columns: ["n"], rows: [], num_rows: 2500}
                       }}

      assert_received {[:lotus, :query, :stop], %{row_count: 2500}, _}
    end

    test "a saved query streams with its variables" do
      query =
        query_fixture(%{
          statement: "SELECT n FROM generate_series(1, {{last}}::int) AS s(n)",
          variables: [%{name: "last", type: :number, default: "3"}]
        })

      assert {:ok, [%Result{rows: [[1], [2], [3]]}]} =
               Lotus.stream_query(query, [], &Enum.to_list/1)

      assert {:ok, [%Result{rows: [[1], [2]]}]} =
               Lotus.stream_query(query, [vars: %{"last" => "2"}], &Enum.to_list/1)
    end

    test "a stream takes no :window" do
      assert_raise ArgumentError, ~r/no :window/, fn ->
        Lotus.stream_statement(@series, [], [window: [limit: 10]], &Enum.to_list/1)
      end
    end
  end

  describe "Lotus.Export.stream/4" do
    setup do
      %{
        query:
          query_fixture(%{
            statement:
              "SELECT n, 'row ' || n AS label FROM generate_series(1, 3) AS s(n) ORDER BY n"
          })
      }
    end

    test "CSV: the header, then a line per row, as to_csv/2 writes them", %{query: query} do
      assert {:ok, csv} =
               Lotus.Export.stream(
                 query,
                 :csv,
                 [chunk_size: 2],
                 &IO.iodata_to_binary(Enum.to_list(&1))
               )

      assert csv == query |> Lotus.Export.to_csv() |> IO.iodata_to_binary()
      assert csv == "n,label\n1,row 1\n2,row 2\n3,row 3\n"
    end

    test "JSONL: an object per row, one per line", %{query: query} do
      assert {:ok, jsonl} =
               Lotus.Export.stream(query, :jsonl, [], &IO.iodata_to_binary(Enum.to_list(&1)))

      assert jsonl |> String.split("\n", trim: true) |> Enum.map(&Lotus.JSON.decode!/1) == [
               %{"n" => 1, "label" => "row 1"},
               %{"n" => 2, "label" => "row 2"},
               %{"n" => 3, "label" => "row 3"}
             ]
    end
  end

  @tag :sqlite
  test "SQLite streams" do
    assert {:ok, chunks} =
             Lotus.stream_statement(
               "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 5) SELECT n FROM s",
               [],
               [repo: "sqlite", chunk_size: 2],
               &Enum.to_list/1
             )

    assert chunks |> Enum.flat_map(& &1.rows) == [[1], [2], [3], [4], [5]]
    assert Enum.all?(chunks, &(&1.columns == ["n"]))
  end

  describe "column policies on SQLite" do
    @describetag :sqlite

    setup do
      SqliteRepo.query!(
        "INSERT INTO test_users (name, email, age, inserted_at, updated_at) " <>
          "VALUES ('a', 'a@example.com', 30, '2024-01-01', '2024-01-01')"
      )

      stub(Lotus.Config, :visibility_for_source_name, fn _source ->
        %{
          column: [
            {"test_users", "email", [action: :mask, mask: {:fixed, "REDACTED"}]},
            {"test_users", "metadata", :omit},
            {"test_users", "age", :error}
          ]
        }
      end)

      :ok
    end

    defp sqlite_stream(sql) do
      Lotus.stream_statement(sql, [], [repo: "sqlite"], &Enum.to_list/1)
    end

    test "a streamed result is masked and omitted as a run's is" do
      sql = "SELECT name, email, metadata FROM test_users"

      assert {:ok, %Result{columns: columns, rows: rows}} =
               Lotus.run_statement(sql, [], repo: "sqlite")

      assert {:ok, chunks} = sqlite_stream(sql)
      assert Enum.all?(chunks, &(&1.columns == columns))
      assert Enum.flat_map(chunks, & &1.rows) == rows
      assert columns == ["name", "email"]
      assert rows == [["a", "REDACTED"]]
    end

    test "a streamed hidden column is refused as in a run" do
      assert {:error, "Query selects hidden column(s): age"} =
               sqlite_stream("SELECT name, age FROM test_users")
    end

    test "a CSV export has the header and the masked values" do
      query = %Query{
        statement: "SELECT name, email FROM test_users",
        data_source: "sqlite",
        variables: []
      }

      assert {:ok, csv} =
               Lotus.Export.stream(
                 query,
                 :csv,
                 [],
                 &(&1 |> Enum.to_list() |> IO.iodata_to_binary())
               )

      assert csv == "name,email\na,REDACTED\n"
    end
  end

  test "a chunk whose rows its columns don't name is refused under a column policy" do
    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{column: [{"users", "secret", :omit}]}
    end)

    stub(Adapter, :capability?, fn
      _adapter, :streaming -> true
      adapter, capability -> call_original(Adapter, :capability?, [adapter, capability])
    end)

    stub(Adapter, :stream_query, fn _adapter, _body, _params, _opts ->
      {:ok, [%{columns: [], rows: [[1, "s"]]}]}
    end)

    tables = %{"users" => %{columns: ["id", "secret"], rows: [[1, "s"]], types: %{}}}
    adapter = InMemoryAdapter.adapter("mem", InMemoryAdapter.dataset(tables: tables))
    statement = %Statement{adapter: InMemoryAdapter, body: %{from: "users"}}

    assert {:error, "The source returned rows whose columns it didn't name" <> _} =
             Runner.stream(adapter, statement, [], &Enum.to_list/1)
  end

  @tag :mysql
  test "MySQL streams" do
    assert {:ok, chunks} =
             Lotus.stream_statement(
               "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 5) SELECT n FROM s",
               [],
               [repo: "mysql", chunk_size: 2],
               &Enum.to_list/1
             )

    assert chunks |> Enum.flat_map(& &1.rows) == [[1], [2], [3], [4], [5]]
  end

  test "an adapter that does not stream runs the statement once and hands the rows over in chunks" do
    tables = %{
      "users" => %{
        columns: ["id"],
        rows: Enum.map(1..5, &[&1]),
        types: %{"id" => "integer"}
      }
    }

    adapter = InMemoryAdapter.adapter("mem", InMemoryAdapter.dataset(tables: tables))
    statement = %Statement{adapter: InMemoryAdapter, body: %{from: "users"}}

    assert {:ok, chunks} = Runner.stream(adapter, statement, [chunk_size: 2], &Enum.to_list/1)
    assert sizes(chunks) == [2, 2, 1]
  end
end
