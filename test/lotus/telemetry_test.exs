defmodule Lotus.TelemetryTest do
  use Lotus.Case, async: true

  alias Lotus.Fixtures
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.Repo

  @pg_adapter EctoAdapter.wrap("postgres", Repo)

  setup do
    fixtures = Fixtures.setup_test_data()
    {:ok, fixtures}
  end

  describe "query telemetry events" do
    test "emits start and stop events on successful query" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :query, :start], [:lotus, :query, :stop]],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1 AS num"))

      assert_received {:telemetry, [:lotus, :query, :start], %{system_time: _},
                       %{repo: "postgres", statement: %Statement{text: "SELECT 1 AS num"}}}

      assert_received {:telemetry, [:lotus, :query, :stop], measurements,
                       %{
                         repo: "postgres",
                         statement: %Statement{text: "SELECT 1 AS num"},
                         result: %Lotus.Result{}
                       }}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert measurements.row_count >= 0

      :telemetry.detach("#{inspect(ref)}")
    end

    test "includes context in start and stop metadata" do
      ref = make_ref()
      pid = self()
      ctx = %{request_id: "req-123", controller: "ReportsController"}

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :query, :start], [:lotus, :query, :stop]],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} =
        Runner.run_statement(@pg_adapter, Statement.new("SELECT 1 AS num", []), context: ctx)

      assert_received {:telemetry, [:lotus, :query, :start], _,
                       %{repo: "postgres", context: ^ctx}}

      assert_received {:telemetry, [:lotus, :query, :stop], _, %{repo: "postgres", context: ^ctx}}

      :telemetry.detach("#{inspect(ref)}")
    end

    test "context defaults to nil when not provided" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :query, :start], [:lotus, :query, :stop]],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _result} = Runner.run_statement(@pg_adapter, Statement.new("SELECT 1 AS num"))

      assert_received {:telemetry, [:lotus, :query, :start], _, %{context: nil}}
      assert_received {:telemetry, [:lotus, :query, :stop], _, %{context: nil}}

      :telemetry.detach("#{inspect(ref)}")
    end

    test "includes context in exception metadata" do
      ref = make_ref()
      pid = self()
      ctx = %{request_id: "req-456"}

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :query, :exception]],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:error, _} =
        Runner.run_statement(@pg_adapter, Statement.new("DROP TABLE test_users", []),
          context: ctx
        )

      assert_received {:telemetry, [:lotus, :query, :exception], _,
                       %{kind: :error, context: ^ctx}}

      :telemetry.detach("#{inspect(ref)}")
    end

    test "emits start and exception events on failed query" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :query, :start], [:lotus, :query, :exception]],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:error, _} = Runner.run_statement(@pg_adapter, Statement.new("DROP TABLE test_users"))

      assert_received {:telemetry, [:lotus, :query, :start], %{system_time: _},
                       %{repo: "postgres", statement: %Statement{text: "DROP TABLE test_users"}}}

      assert_received {:telemetry, [:lotus, :query, :exception], measurements,
                       %{
                         kind: :error,
                         repo: "postgres",
                         statement: %Statement{text: "DROP TABLE test_users"}
                       }}

      assert is_integer(measurements.duration)

      :telemetry.detach("#{inspect(ref)}")
    end
  end

  describe "schema introspection telemetry events" do
    @tag :sqlite
    test "emits start and stop events for list_tables" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [
          [:lotus, :schema, :introspection, :start],
          [:lotus, :schema, :introspection, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _tables} = Lotus.Schema.list_tables("sqlite")

      assert_received {:telemetry, [:lotus, :schema, :introspection, :start], %{system_time: _},
                       %{operation: :list_tables, repo: "sqlite"}}

      assert_received {:telemetry, [:lotus, :schema, :introspection, :stop],
                       %{duration: duration},
                       %{operation: :list_tables, repo: "sqlite", result: :ok}}

      assert is_integer(duration)
      assert duration >= 0

      :telemetry.detach("#{inspect(ref)}")
    end

    @tag :sqlite
    test "emits start and stop events for describe_table" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [
          [:lotus, :schema, :introspection, :start],
          [:lotus, :schema, :introspection, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _schema} = Lotus.Schema.describe_table("sqlite", "products")

      assert_received {:telemetry, [:lotus, :schema, :introspection, :start], _,
                       %{operation: :describe_table, repo: "sqlite"}}

      assert_received {:telemetry, [:lotus, :schema, :introspection, :stop], %{duration: _},
                       %{operation: :describe_table, repo: "sqlite", result: :ok}}

      :telemetry.detach("#{inspect(ref)}")
    end

    @tag :sqlite
    test "emits start and stop events for list_schemas" do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [
          [:lotus, :schema, :introspection, :start],
          [:lotus, :schema, :introspection, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _schemas} = Lotus.Schema.list_schemas("sqlite")

      assert_received {:telemetry, [:lotus, :schema, :introspection, :start], _,
                       %{operation: :list_schemas, repo: "sqlite"}}

      assert_received {:telemetry, [:lotus, :schema, :introspection, :stop], %{duration: _},
                       %{operation: :list_schemas, result: :ok}}

      :telemetry.detach("#{inspect(ref)}")
    end
  end
end
