defmodule Lotus.Storage.MutationTest do
  @moduledoc """
  `Lotus.Storage.Mutation.run/4` is the one path every content write takes:
  `:before_content_change`, then the repo call, then `:after_content_change`
  and the `[:lotus, :content, :change]` telemetry event.
  """

  use Lotus.Case

  alias Lotus.Middleware
  alias Lotus.Storage.{Mutation, Query}

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

  defmodule RaisePlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: raise("plug failed")
  end

  @attrs %{name: "Active users", statement: "SELECT 1"}

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

  defp attach_content_telemetry(context) do
    pid = self()
    handler_id = "content-change-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:lotus, :content, :change],
      fn event, measurements, %{context: ^context} = metadata, _config ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "a change the plugs let through" do
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
      {:ok, query} = @attrs |> Query.new() |> Mutation.run(:create, :query, [])
      count_on_both_events()

      assert {:ok, %Query{name: "Renamed"} = renamed} =
               query |> Query.update(%{name: "Renamed"}) |> Mutation.run(:update, :query, [])

      assert_received {:before_content_change, %{op: :update, record: ^query}, 1}

      assert_received {:after_content_change,
                       %{op: :update, record: ^renamed, changes: %{name: "Renamed"}}, 1}
    end

    test "a delete fires before the row goes and after it is gone" do
      {:ok, query} = @attrs |> Query.new() |> Mutation.run(:create, :query, [])
      count_on_both_events()

      assert {:ok, %Query{}} =
               query |> Ecto.Changeset.change() |> Mutation.run(:delete, :query, [])

      assert_received {:before_content_change, %{op: :delete, record: ^query}, 1}
      assert_received {:after_content_change, %{op: :delete, changes: changes}, 0}
      assert changes == %{}
    end

    test "writes without middleware configured" do
      assert {:ok, %Query{}} = @attrs |> Query.new() |> Mutation.run(:create, :query, [])
    end

    test "the context is nil when the caller passes none" do
      count_on_both_events()

      assert {:ok, _query} = @attrs |> Query.new() |> Mutation.run(:create, :query, [])

      assert_received {:before_content_change, %{context: nil}, 0}
      assert_received {:after_content_change, %{context: nil}, 1}
    end
  end

  describe "a halt on :before_content_change" do
    test "returns {:error, {:halted, reason}} and writes nothing" do
      Middleware.compile(%{
        before_content_change: [{HaltPlug, "read only"}],
        after_content_change: [{CountingPlug, :after_content_change}]
      })

      assert {:error, {:halted, "read only"}} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, [])

      assert Repo.aggregate(Query, :count) == 0
      refute_received {:after_content_change, _payload, _count}
    end

    test "a plug that raises halts with the exception as the reason" do
      Middleware.compile(%{before_content_change: [{RaisePlug, []}]})

      assert {:error, {:halted, %RuntimeError{message: "plug failed"}}} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, [])

      assert Repo.aggregate(Query, :count) == 0
    end

    test "emits no telemetry" do
      context = %{request: make_ref()}
      attach_content_telemetry(context)
      Middleware.compile(%{before_content_change: [{HaltPlug, "read only"}]})

      assert {:error, {:halted, _reason}} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, context: context)

      refute_received {:telemetry, _event, _measurements, _metadata}
    end
  end

  describe "an invalid changeset" do
    test "still fires :before_content_change, so a refusal is not preceded by validation errors" do
      Middleware.compile(%{before_content_change: [{HaltPlug, "read only"}]})

      assert {:error, {:halted, "read only"}} =
               %{} |> Query.new() |> Mutation.run(:create, :query, [])
    end

    test "returns the changeset error and fires no :after_content_change" do
      count_on_both_events()

      assert {:error, %Ecto.Changeset{valid?: false}} =
               %{} |> Query.new() |> Mutation.run(:create, :query, [])

      assert_received {:before_content_change, %{changeset: %Ecto.Changeset{valid?: false}}, 0}
      refute_received {:after_content_change, _payload, _count}
    end
  end

  describe ":after_content_change" do
    test "a halt there does not undo the write or change the return value" do
      Middleware.compile(%{after_content_change: [{HaltPlug, "ignored"}]})

      assert {:ok, %Query{}} = @attrs |> Query.new() |> Mutation.run(:create, :query, [])
      assert Repo.aggregate(Query, :count) == 1
    end

    test "is mirrored by [:lotus, :content, :change] telemetry" do
      context = %{request: make_ref()}
      attach_content_telemetry(context)

      assert {:ok, query} =
               @attrs |> Query.new() |> Mutation.run(:create, :query, context: context)

      assert_received {:telemetry, [:lotus, :content, :change], %{count: 1}, metadata}

      assert %{op: :create, resource: :query, record: ^query, context: ^context} = metadata
      assert %{name: "Active users"} = metadata.changes
    end
  end
end
