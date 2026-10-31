defmodule Lotus.CancelTest do
  # Cancels from another pooled connection, so each test starts a repo with a
  # real pool instead of the sandbox.
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Runner.Cancel
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.{MysqlRepo, Repo}

  @cancelled "The query was cancelled."

  setup :set_mimic_global

  defp start_pool(repo) do
    opts = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 2]
    id = {repo, System.unique_integer([:positive])}
    pid = start_supervised!(Supervisor.child_spec({repo, opts}, id: id))
    EctoAdapter.wrap(name(repo), %{repo: repo, dynamic: pid})
  end

  defp name(Repo), do: "postgres"
  defp name(MysqlRepo), do: "mysql"

  defp use_source(%Adapter{} = adapter) do
    stub(Lotus.Source, :resolve!, fn _source, _fallback -> adapter end)
    adapter
  end

  # Runs `fun` in this process; cancels the statement from another one as
  # soon as its token arrives.
  defp run_and_cancel(fun) do
    test = self()

    canceller =
      spawn_link(fn ->
        receive do
          {:token, token} ->
            send(test, {:cancel_result, Lotus.cancel(token)})
        end
      end)

    {elapsed_us, result} = :timer.tc(fn -> fun.(&send(canceller, {:token, &1})) end)
    {result, div(elapsed_us, 1000)}
  end

  describe "the capability" do
    test "Postgres and MySQL can cancel, SQLite cannot" do
      assert Lotus.cancellable?("postgres")
      assert Lotus.cancellable?("mysql")
      refute Lotus.cancellable?("sqlite")
    end

    test "dispatch to an adapter without it is unsupported" do
      adapter = EctoAdapter.wrap("sqlite", Lotus.Test.SqliteRepo)

      assert {:error, :unsupported} = Adapter.cancel_handle(adapter)
      assert {:error, :unsupported} = Adapter.cancel(adapter, 1)
    end
  end

  describe "Postgres" do
    setup do
      %{adapter: Repo |> start_pool() |> use_source()}
    end

    test "a statement cancelled from another process returns the cancelled error" do
      {result, ms} =
        run_and_cancel(fn on_token ->
          Lotus.run_statement("SELECT pg_sleep(5)", [], on_cancel_token: on_token)
        end)

      assert result == {:error, @cancelled}
      assert_receive {:cancel_result, :ok}
      assert ms < 3_000
    end

    test "a saved query run is cancelled the same way" do
      query = %Lotus.Storage.Query{
        id: nil,
        name: "slow",
        statement: "SELECT pg_sleep(5)",
        data_source: "postgres",
        variables: []
      }

      {result, ms} =
        run_and_cancel(fn on_token -> Lotus.run_query(query, on_cancel_token: on_token) end)

      assert result == {:error, @cancelled}
      assert ms < 3_000
    end

    test "the connection is usable after a cancel", %{adapter: adapter} do
      {{:error, @cancelled}, _ms} =
        run_and_cancel(fn on_token ->
          Lotus.run_statement("SELECT pg_sleep(5)", [], on_cancel_token: on_token)
        end)

      assert {:ok, %{rows: [[1]]}} = Lotus.run_statement("SELECT 1")
      assert {:ok, %{rows: [[1]]}} = Adapter.execute_query(adapter, "SELECT 1", [], [])
    end

    test "a token is spent once its statement returned" do
      test = self()

      assert {:ok, %{rows: [[1]]}} =
               Lotus.run_statement("SELECT 1", [], on_cancel_token: &send(test, {:token, &1}))

      assert_receive {:token, token}
      assert {:error, "The query is not running."} = Lotus.cancel(token)
    end

    test "the cancelled run is an error to telemetry and middleware" do
      ref = make_ref()
      test = self()

      :telemetry.attach_many(
        "cancel-test-#{inspect(ref)}",
        [[:lotus, :run, :exception], [:lotus, :query, :exception]],
        fn event, _measurements, meta, _config -> send(test, {:event, event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("cancel-test-#{inspect(ref)}") end)

      {{:error, @cancelled}, _ms} =
        run_and_cancel(fn on_token ->
          Lotus.run_statement("SELECT pg_sleep(5)", [], on_cancel_token: on_token)
        end)

      assert_receive {:event, [:lotus, :query, :exception], _meta}
      assert_receive {:event, [:lotus, :run, :exception], %{phase: :execute, reason: @cancelled}}
    end

    test "the result cache does not store a cancelled run" do
      Lotus.Config
      |> stub(:cache_adapter, fn -> {:ok, Lotus.Cache.ETS} end)
      |> stub(:cache_namespace, fn -> "cancel_test" end)

      :ets.delete_all_objects(:lotus_cache)

      {{:error, @cancelled}, _ms} =
        run_and_cancel(fn on_token ->
          Lotus.run_statement("SELECT pg_sleep(5)", [], on_cancel_token: on_token)
        end)

      assert :ets.info(:lotus_cache, :size) == 0

      assert {:ok, %{rows: [[1]]}} = Lotus.run_statement("SELECT 1")
      assert :ets.info(:lotus_cache, :size) == 1
    end
  end

  describe "MySQL" do
    @describetag :mysql

    setup do
      %{adapter: MysqlRepo |> start_pool() |> use_source()}
    end

    test "a statement cancelled from another process returns the cancelled error" do
      # SLEEP() is not read-only in MySQL's judgement, and returns 1 when killed.
      {result, ms} =
        run_and_cancel(fn on_token ->
          Lotus.run_statement("SELECT SLEEP(5)", [],
            read_only: false,
            on_cancel_token: on_token
          )
        end)

      assert result == {:error, @cancelled}
      assert_receive {:cancel_result, :ok}
      assert ms < 3_000
    end

    test "the connection is usable after a cancel" do
      {{:error, @cancelled}, _ms} =
        run_and_cancel(fn on_token ->
          Lotus.run_statement("SELECT SLEEP(5)", [], read_only: false, on_cancel_token: on_token)
        end)

      assert {:ok, %{rows: [[1]]}} = Lotus.run_statement("SELECT 1")
    end
  end

  describe "a cancel on its way when the statement returns" do
    # The adapter refuses the first cancel and is slow with the second; the
    # statement returns while the second is on its way. Its connection must
    # not go back to the pool before that cancel lands.
    setup do
      calls = :counters.new(1, [])
      released = :atomics.new(1, [])
      test = self()

      stub(Adapter, :cancel_handle, fn _adapter -> {:ok, 7} end)

      stub(Adapter, :cancel, fn _adapter, 7 ->
        :counters.add(calls, 1, 1)

        case :counters.get(calls, 1) do
          1 ->
            {:error, "refused"}

          _ ->
            Process.sleep(500)
            send(test, {:landed, :atomics.get(released, 1) == 1})
            :ok
        end
      end)

      %{adapter: EctoAdapter.wrap("postgres", Repo), released: released}
    end

    test "the statement waits for it, after a refused one", %{
      adapter: adapter,
      released: released
    } do
      test = self()
      token = Cancel.prepare(adapter, on_cancel_token: &send(test, {:token, &1}))

      owner =
        Task.async(fn ->
          result =
            Cancel.run(token, [on_cancel_token: &send(test, {:token, &1})], fn ->
              Process.sleep(300)
              :done
            end)

          :atomics.put(released, 1, 1)
          result
        end)

      assert_receive {:token, token}
      Process.sleep(50)
      assert {:error, "refused"} = Lotus.cancel(token)

      Process.sleep(150)
      canceller = Task.async(fn -> Lotus.cancel(token) end)

      assert_receive {:landed, false}, 2_000
      assert :ok = Task.await(canceller)
      assert {:error, @cancelled} = Task.await(owner)
    end
  end

  describe "a source that cannot cancel" do
    @describetag :sqlite

    test "the function is not called and the statement runs" do
      test = self()

      assert {:ok, %{rows: [[1]]}} =
               Lotus.run_statement("SELECT 1", [],
                 repo: "sqlite",
                 on_cancel_token: &send(test, {:token, &1})
               )

      refute_received {:token, _}
    end
  end
end
