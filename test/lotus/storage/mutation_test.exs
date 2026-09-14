defmodule Lotus.Storage.MutationTest do
  @moduledoc """
  `Lotus.Storage.Mutation` is the one path every content write takes:
  `:before_content_change`, the repo call, `:after_content_change`, and the
  `[:lotus, :content, :change, *]` telemetry span around all of it.
  """

  use Lotus.Case

  import ExUnit.CaptureLog

  alias Lotus.Middleware
  alias Lotus.Storage.{Dashboard, DashboardCard, Mutation, Query, QueryVariable}

  defmodule CountingPlug do
    @moduledoc false
    alias Lotus.Storage.Query
    alias Lotus.Test.Repo

    def init(event), do: event

    def call(payload, event) do
      count = Repo.aggregate(Query, :count)
      send(self(), {event, payload, count})
      {:cont, payload}
    end
  end

  defmodule HaltPlug do
    @moduledoc false
    def init(reason), do: reason
    def call(_payload, reason), do: {:halt, reason}
  end

  defmodule HaltOnNamePlug do
    @moduledoc false
    def init(name), do: name

    def call(%{changeset: %{changes: %{name: name}}}, name), do: {:halt, "no #{name}"}
    def call(payload, _name), do: {:cont, payload}
  end

  defmodule RaisePlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: raise("plug failed")
  end

  defmodule ThrowPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: throw(:plug_threw)
  end

  defmodule NotifyPlug do
    @moduledoc false
    def init(tag), do: tag

    def call(payload, tag) do
      send(self(), {tag, payload})
      {:cont, payload}
    end
  end

  @attrs %{name: "Active users", statement: "SELECT 1"}

  @span_events [
    [:lotus, :content, :change, :start],
    [:lotus, :content, :change, :stop],
    [:lotus, :content, :change, :exception]
  ]

  setup do
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)
    :ok
  end

  defp count_on_both_events do
    Middleware.compile(%{
      before_content_change: [{CountingPlug, :before_content_change}],
      after_content_change: [{CountingPlug, :after_content_change}]
    })
  end

  defp attach_span(context) do
    pid = self()
    handler_id = "content-change-#{inspect(make_ref())}"

    :telemetry.attach_many(
      handler_id,
      @span_events,
      fn event, measurements, metadata, _config ->
        if metadata.context == context do
          send(pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp create_query(attrs \\ @attrs) do
    attrs |> Query.new() |> Mutation.run(:create, :query, [])
  end

  describe "run/4 on a change the plugs let through" do
    test "fires :before_content_change before the insert and :after_content_change after it" do
      count_on_both_events()

      assert {:ok, %Query{} = query} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, context: %{user_id: 7})

      assert_received {:before_content_change, before_payload, 0}
      assert_received {:after_content_change, written_payload, 1}

      assert %{op: :create, resource: :query, record: nil, context: %{user_id: 7}} =
               before_payload

      assert %Ecto.Changeset{data: %Query{id: nil}} = before_payload.changeset

      assert %{op: :create, resource: :query, record: ^query, context: %{user_id: 7}} =
               written_payload

      assert %{name: "Active users", statement: "SELECT 1"} = written_payload.changes
    end

    test "an update carries the current record before and the written record after" do
      {:ok, query} = create_query()
      count_on_both_events()

      assert {:ok, %Query{name: "Renamed"} = renamed} =
               query |> Query.update(%{name: "Renamed"}) |> Mutation.run(:update, :query, [])

      assert_received {:before_content_change, %{op: :update, record: ^query}, 1}

      assert_received {:after_content_change,
                       %{op: :update, record: ^renamed, changes: %{name: "Renamed"}}, 1}
    end

    test "a delete fires before the row goes and after it is gone" do
      {:ok, query} = create_query()
      count_on_both_events()

      assert {:ok, %Query{}} =
               query |> Ecto.Changeset.change() |> Mutation.run(:delete, :query, [])

      assert_received {:before_content_change, %{op: :delete, record: ^query}, 1}
      assert_received {:after_content_change, %{op: :delete, changes: changes}, 0}
      assert changes == %{}
    end

    test "a delete takes the bare struct" do
      {:ok, query} = create_query()
      count_on_both_events()

      assert {:ok, %Query{}} = Mutation.run(query, :delete, :query, [])

      assert_received {:before_content_change,
                       %{op: :delete, record: ^query, changeset: %Ecto.Changeset{data: ^query}},
                       1}

      assert Repo.aggregate(Query, :count) == 0
    end

    test "writes without middleware configured" do
      assert {:ok, %Query{}} = create_query()
    end

    test "the context is nil when the caller passes none" do
      count_on_both_events()

      assert {:ok, _query} = create_query()

      assert_received {:before_content_change, %{context: nil}, 0}
      assert_received {:after_content_change, %{context: nil}, 1}
    end
  end

  describe ":changes" do
    test "carries the written values of embedded fields, not their changesets" do
      Middleware.compile(%{after_content_change: [{NotifyPlug, :written}]})

      assert {:ok, query} =
               Mutation.run(
                 Query.new(%{
                   name: "By region",
                   statement: "SELECT {{region}}",
                   variables: [%{name: "region", type: :text}]
                 }),
                 :create,
                 :query,
                 []
               )

      assert_received {:written, %{resource: :query, changes: query_changes}}
      assert [%QueryVariable{name: "region"}] = query_changes.variables
      assert query_changes.variables == query.variables

      {:ok, dashboard} = Mutation.run(Dashboard.new(%{name: "Sales"}), :create, :dashboard, [])

      assert {:ok, card} =
               Mutation.run(
                 DashboardCard.new(%{
                   dashboard_id: dashboard.id,
                   card_type: :text,
                   position: 0,
                   layout: %{x: 0, y: 0, w: 6, h: 4}
                 }),
                 :create,
                 :dashboard_card,
                 []
               )

      assert_received {:written, %{resource: :dashboard_card, changes: card_changes}}
      refute match?(%Ecto.Changeset{}, card_changes.layout)
      assert card_changes.layout == card.layout
    end
  end

  describe "an update that changes nothing" do
    test "fires :before_content_change but no :after_content_change" do
      {:ok, query} = create_query()
      count_on_both_events()

      assert {:ok, ^query} =
               query |> Query.update(%{name: query.name}) |> Mutation.run(:update, :query, [])

      assert_received {:before_content_change, %{op: :update}, 1}
      refute_received {:after_content_change, _payload, _count}
    end

    test "closes the telemetry span with :stop and empty changes" do
      {:ok, query} = create_query()
      context = %{request: make_ref()}
      attach_span(context)

      assert {:ok, _query} =
               query
               |> Query.update(%{name: query.name})
               |> Mutation.run(:update, :query, context: context)

      assert_received {:telemetry, [:lotus, :content, :change, :stop], _measurements,
                       %{changes: changes}}

      assert changes == %{}
    end
  end

  describe "a halt on :before_content_change" do
    test "returns {:error, {:halted, reason}} and writes nothing" do
      Middleware.compile(%{
        before_content_change: [{HaltPlug, "read only"}],
        after_content_change: [{CountingPlug, :after_content_change}]
      })

      assert {:error, {:halted, "read only"}} = create_query()

      assert Repo.aggregate(Query, :count) == 0
      refute_received {:after_content_change, _payload, _count}
    end

    test "a plug that raises halts with the exception as the reason" do
      Middleware.compile(%{before_content_change: [{RaisePlug, []}]})

      assert {:error, {:halted, %RuntimeError{message: "plug failed"}}} = create_query()
      assert Repo.aggregate(Query, :count) == 0
    end

    test "a plug that throws closes the span with :exception and the throw propagates" do
      context = %{request: make_ref()}
      attach_span(context)
      Middleware.compile(%{before_content_change: [{ThrowPlug, []}]})

      assert :plug_threw =
               catch_throw(
                 @attrs
                 |> Query.new()
                 |> Mutation.run(:create, :query, context: context)
               )

      assert_received {:telemetry, [:lotus, :content, :change, :exception], _measurements,
                       %{kind: :throw, reason: :plug_threw, stacktrace: [_ | _]}}

      assert Repo.aggregate(Query, :count) == 0
    end
  end

  describe "an invalid changeset" do
    test "still fires :before_content_change, so a refusal is not preceded by validation errors" do
      Middleware.compile(%{before_content_change: [{HaltPlug, "read only"}]})

      assert {:error, {:halted, "read only"}} = create_query(%{})
    end

    test "returns the changeset error and fires no :after_content_change" do
      count_on_both_events()

      assert {:error, %Ecto.Changeset{valid?: false}} = create_query(%{})

      assert_received {:before_content_change, %{changeset: %Ecto.Changeset{valid?: false}}, 0}
      refute_received {:after_content_change, _payload, _count}
    end
  end

  describe ":after_content_change" do
    test "a halt there does not undo the write or change the return value, and is logged" do
      Middleware.compile(%{
        after_content_change: [{HaltPlug, "too late"}, {NotifyPlug, :later_plug}]
      })

      log =
        capture_log(fn ->
          assert {:ok, %Query{}} = create_query()
        end)

      assert Repo.aggregate(Query, :count) == 1
      assert log =~ ":after_content_change"
      assert log =~ "\"too late\""
      refute_received {:later_plug, _payload}
    end

    test "a plug that raises is logged with the exception and the write stands" do
      context = %{request: make_ref()}
      attach_span(context)
      Middleware.compile(%{after_content_change: [{RaisePlug, []}]})

      log =
        capture_log(fn ->
          assert {:ok, %Query{}} =
                   @attrs |> Query.new() |> Mutation.run(:create, :query, context: context)
        end)

      assert log =~ "plug failed"
      assert Repo.aggregate(Query, :count) == 1
      assert_received {:telemetry, [:lotus, :content, :change, :stop], _measurements, _metadata}
    end

    test "a plug that throws is caught and logged, and the span still closes with :stop" do
      context = %{request: make_ref()}
      attach_span(context)
      Middleware.compile(%{after_content_change: [{ThrowPlug, []}]})

      log =
        capture_log(fn ->
          assert {:ok, %Query{}} =
                   @attrs |> Query.new() |> Mutation.run(:create, :query, context: context)
        end)

      assert log =~ ":plug_threw"
      assert Repo.aggregate(Query, :count) == 1
      assert_received {:telemetry, [:lotus, :content, :change, :stop], _measurements, _metadata}
      refute_received {:telemetry, [:lotus, :content, :change, :exception], _m, _metadata}
    end
  end

  describe "the telemetry span" do
    test "a write emits :start with the stored record and :stop with the written one" do
      context = %{request: make_ref()}
      attach_span(context)

      assert {:ok, query} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, context: context)

      assert_received {:telemetry, [:lotus, :content, :change, :start], %{system_time: _},
                       %{op: :create, resource: :query, record: nil, context: ^context}}

      assert_received {:telemetry, [:lotus, :content, :change, :stop], %{duration: duration},
                       %{op: :create, resource: :query, record: ^query, changes: changes}}

      assert is_integer(duration)
      assert %{name: "Active users"} = changes
    end

    test "a refusal emits :exception with the reason the caller receives" do
      context = %{request: make_ref()}
      attach_span(context)
      Middleware.compile(%{before_content_change: [{HaltPlug, "read only"}]})

      assert {:error, {:halted, "read only"} = reason} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, context: context)

      assert_received {:telemetry, [:lotus, :content, :change, :start], _measurements, _metadata}

      assert_received {:telemetry, [:lotus, :content, :change, :exception], %{duration: _},
                       %{op: :create, resource: :query, kind: :error, reason: ^reason}}

      refute_received {:telemetry, [:lotus, :content, :change, :stop], _m, _metadata}
    end

    test "a validation failure emits :exception with the changeset" do
      context = %{request: make_ref()}
      attach_span(context)

      assert {:error, %Ecto.Changeset{}} =
               %{} |> Query.new() |> Mutation.run(:create, :query, context: context)

      assert_received {:telemetry, [:lotus, :content, :change, :exception], _measurements,
                       %{kind: :error, reason: %Ecto.Changeset{valid?: false}}}
    end
  end

  describe "run_all/2" do
    test "runs every before event, then every write, then every after event" do
      count_on_both_events()

      assert {:ok, [%Query{name: "First"}, %Query{name: "Second"}]} =
               Mutation.run_all(
                 [
                   {Query.new(%{name: "First", statement: "SELECT 1"}), :create, :query},
                   {Query.new(%{name: "Second", statement: "SELECT 2"}), :create, :query}
                 ],
                 []
               )

      assert_received {:before_content_change, %{changeset: %{changes: %{name: "First"}}}, 0}
      assert_received {:before_content_change, %{changeset: %{changes: %{name: "Second"}}}, 0}
      assert_received {:after_content_change, %{record: %Query{name: "First"}}, 2}
      assert_received {:after_content_change, %{record: %Query{name: "Second"}}, 2}
    end

    test "a halt on any change writes none of them and closes every span with the reason" do
      context = %{request: make_ref()}
      attach_span(context)

      Middleware.compile(%{
        before_content_change: [{HaltOnNamePlug, "Second"}],
        after_content_change: [{CountingPlug, :after_content_change}]
      })

      assert {:error, {:halted, "no Second"} = reason} =
               Mutation.run_all(
                 [
                   {Query.new(%{name: "First", statement: "SELECT 1"}), :create, :query},
                   {Query.new(%{name: "Second", statement: "SELECT 2"}), :create, :query}
                 ],
                 context: context
               )

      assert Repo.aggregate(Query, :count) == 0
      refute_received {:after_content_change, _payload, _count}

      for _change <- 1..2 do
        assert_received {:telemetry, [:lotus, :content, :change, :exception], _measurements,
                         %{reason: ^reason}}
      end
    end

    test "a failed write rolls back the writes before it and fires no after event" do
      count_on_both_events()

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Mutation.run_all(
                 [
                   {Query.new(%{name: "First", statement: "SELECT 1"}), :create, :query},
                   {Query.new(%{}), :create, :query}
                 ],
                 []
               )

      assert Repo.aggregate(Query, :count) == 0
      refute_received {:after_content_change, _payload, _count}
    end

    test "an empty list writes nothing" do
      count_on_both_events()

      assert {:ok, []} = Mutation.run_all([], [])
      refute_received {:before_content_change, _payload, _count}
    end
  end
end
