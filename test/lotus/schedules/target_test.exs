defmodule Lotus.Schedules.TargetTest do
  @moduledoc """
  Schedule targets registered by name (`Lotus.Schedules.Target`), as Lotus
  Pro adds its workflows: validated with the schedule, run by the scheduler,
  their results delivered or read by an alert as a query's are.
  """
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.{Config, Schedules}
  alias Lotus.Scheduler.Worker
  alias Lotus.Schedules.Targets
  alias Lotus.Storage.ScheduleRun

  # Boards by id: "rows" returns two rows, "empty" none, "broken" fails.
  defmodule Board do
    @moduledoc false
    @behaviour Lotus.Schedules.Target

    @impl true
    def label, do: "Board"

    @impl true
    def list(_opts), do: [get("rows", []), get("empty", [])]

    @impl true
    def get(id, _opts) when id in ["rows", "empty", "broken"],
      do: %{id: id, name: "Board #{id}", description: nil}

    def get(_id, _opts), do: nil

    @impl true
    def run(schedule, opts) do
      send(:persistent_term.get({__MODULE__, :test}), {:ran, schedule.target_id, opts})

      case schedule.target_id do
        "rows" -> {:ok, [%{title: "Out", result: Lotus.Result.new(["n"], [[1], [2]])}]}
        "empty" -> {:ok, [%{title: "Out", result: Lotus.Result.new(["n"], [])}]}
        "broken" -> {:error, "the board is broken"}
      end
    end
  end

  defmodule Sends do
    @moduledoc false
    @behaviour Lotus.Delivery.Channel
    def formats, do: :any
    def validate_config(_config), do: :ok

    def deliver(content, _attachments, _config) do
      send(:persistent_term.get({Board, :test}), {:delivered, content})
      :ok
    end
  end

  setup do
    stub(Config, :scheduler, fn -> [targets: %{"board" => Board}] end)
    stub(Config, :delivery, fn -> [channels: %{"send" => Sends}] end)
    :persistent_term.put({Board, :test}, self())
    on_exit(fn -> :persistent_term.erase({Board, :test}) end)
    :ok
  end

  defp schedule(attrs) do
    Map.merge(
      %{
        name: "Board",
        target_type: "board",
        target_id: "rows",
        cron: "* * * * *",
        deliveries: [%{channel: "send", format: "json", config: %{}}]
      },
      attrs
    )
    |> Schedules.create_schedule()
  end

  defp run(schedule) do
    {:ok, run} = schedule.id |> ScheduleRun.claim_changeset(DateTime.utc_now()) |> Repo.insert()
    {:ok, run} = Worker.perform(run.id)
    run
  end

  test "a schedule names one registered target, by type and id" do
    assert {:ok, schedule} = schedule(%{})
    assert %{target_type: "board", target_id: "rows"} = schedule
    assert Targets.entry(schedule) == %{id: "rows", name: "Board rows", description: nil}

    assert {:error, changeset} = schedule(%{target_type: "sheet"})
    assert %{target_type: [~s(is not a known target: "sheet")]} = errors_on(changeset)

    assert {:error, changeset} = schedule(%{target_id: nil})
    assert %{target_id: ["can't be blank"]} = errors_on(changeset)

    query = Lotus.Fixtures.query_fixture(%{statement: "SELECT 1"})
    assert {:error, changeset} = schedule(%{query_id: query.id})

    assert %{dashboard_id: ["a schedule runs one query, dashboard or target"]} =
             errors_on(changeset)

    assert [%{id: id}] = Schedules.list_schedules(target_type: "board", target_id: "rows")
    assert id == schedule.id
  end

  test "the scheduler runs it with the run's actor, and delivers its results" do
    {:ok, schedule} = schedule(%{})

    assert %ScheduleRun{status: "succeeded", row_count: 2} = run(schedule)
    assert_received {:ran, "rows", _opts}
    assert_received {:delivered, %{title: "Board", results: [%{title: "Out", result: result}]}}
    assert result.rows == [[1], [2]]
  end

  test "a target that fails, or is no longer registered, fails the run" do
    {:ok, broken} = schedule(%{target_id: "broken"})
    assert %ScheduleRun{status: "failed", error: "the board is broken"} = run(broken)

    {:ok, schedule} = schedule(%{})
    stub(Config, :scheduler, fn -> [] end)

    assert %ScheduleRun{status: "failed", error: ~s(no target is registered as "board")} =
             run(schedule)
  end

  test "an alert reads its first result: sent only when there are rows, naming the target" do
    {:ok, empty} = schedule(%{target_id: "empty", rule: %{condition: "any_rows"}})
    assert %ScheduleRun{status: "succeeded"} = run(empty)
    refute_received {:delivered, _}

    {:ok, rows} = schedule(%{rule: %{condition: "any_rows"}})
    assert %ScheduleRun{status: "succeeded"} = run(rows)
    assert_received {:delivered, %{alert: %{status: "firing", message: message}}}
    assert message == "the board returned 2 rows"
  end
end
