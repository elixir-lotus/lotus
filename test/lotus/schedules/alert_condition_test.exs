defmodule Lotus.Schedules.AlertConditionTest do
  @moduledoc """
  Alert conditions registered by name (`Lotus.Schedules.Alert.Condition`),
  as Lotus Pro adds them: validated with the schedule, evaluated with the
  schedule's state, and sent like the built-in ones.
  """
  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Config, Schedules}
  alias Lotus.Scheduler.Worker
  alias Lotus.Schedules.Alert
  alias Lotus.Storage.{Query, ScheduleRule, ScheduleRun}

  # Fires when the value moves by more than `options["by"]` since the last run.
  defmodule Change do
    @moduledoc false
    @behaviour Lotus.Schedules.Alert.Condition

    @impl true
    def validate(%ScheduleRule{options: %{"by" => by}}) when is_number(by) and by > 0, do: :ok
    def validate(_rule), do: {:error, "needs how much the value may move, as by"}

    @impl true
    def evaluate(%ScheduleRule{column: column, options: %{"by" => by}}, result, state) do
      index = Enum.find_index(result.columns, &(&1 == column))
      [row | _] = result.rows
      value = Enum.at(row, index)

      case state do
        %{"value" => last} when is_number(last) -> {:ok, abs(value - last) > by, value}
        _first_run -> {:ok, false, value}
      end
    end

    @impl true
    def describe(_rule, "firing", value), do: "it moved to #{value}"
    def describe(_rule, "ok", value), do: "it settled at #{value}"
  end

  defmodule Sends do
    @moduledoc false
    @behaviour Lotus.Delivery.Channel
    def formats, do: :any
    def validate_config(_config), do: :ok

    def deliver(content, _attachments, _config) do
      send(:persistent_term.get({__MODULE__, :test}), {:delivered, content.alert})
      :ok
    end
  end

  setup do
    stub(Config, :alerts, fn -> [conditions: %{"change" => Change}] end)
    stub(Config, :delivery, fn -> [channels: %{"send" => Sends}] end)
    stub(Config, :scheduler, fn -> [] end)
    :persistent_term.put({Sends, :test}, self())
    on_exit(fn -> :persistent_term.erase({Sends, :test}) end)

    %{query: query_fixture(%{statement: "SELECT 100 AS n"})}
  end

  defp alert(query, rule) do
    Schedules.create_schedule(%{
      name: "Moves",
      query_id: query.id,
      cron: "* * * * *",
      rule: rule,
      deliveries: [%{channel: "send", format: "json", config: %{}}]
    })
  end

  defp returns(query, n),
    do:
      Repo.update_all(from(q in Query, where: q.id == ^query.id),
        set: [statement: "SELECT #{n} AS n"]
      )

  defp run(schedule) do
    {:ok, run} = schedule.id |> ScheduleRun.claim_changeset(DateTime.utc_now()) |> Repo.insert()
    {:ok, run} = Worker.perform(run.id)
    {run, Schedules.get_schedule!(schedule.id).state}
  end

  test "a registered condition is offered and its settings are checked", %{query: query} do
    assert "change" in Alert.conditions()
    assert "above" in Alert.conditions()

    assert {:error, changeset} = alert(query, %{condition: "change", column: "n"})

    assert %{rule: %{options: ["needs how much the value may move, as by"]}} =
             errors_on(changeset)

    assert {:error, changeset} = alert(query, %{condition: "rising"})
    assert %{rule: %{condition: ["is invalid"]}} = errors_on(changeset)

    assert {:ok, schedule} =
             alert(query, %{condition: "change", column: "n", options: %{"by" => 10}})

    assert %ScheduleRule{condition: "change", options: %{"by" => 10}} = schedule.rule
  end

  test "it reads the last run's value from the state, and sends on a change", %{query: query} do
    {:ok, schedule} = alert(query, %{condition: "change", column: "n", options: %{"by" => 10}})

    assert {%ScheduleRun{status: "succeeded"}, %{"status" => "ok", "value" => 100}} =
             run(schedule)

    refute_received {:delivered, _}

    returns(query, 150)
    assert {_run, %{"status" => "firing", "value" => 150}} = run(schedule)
    assert_received {:delivered, %{status: "firing", message: "it moved to 150"}}

    returns(query, 155)
    assert {_run, %{"status" => "ok"}} = run(schedule)
    assert_received {:delivered, %{status: "ok", message: "it settled at 155"}}
  end

  test "a rule whose condition is no longer registered fails its run", %{query: query} do
    {:ok, schedule} = alert(query, %{condition: "change", column: "n", options: %{"by" => 10}})
    stub(Config, :alerts, fn -> [] end)

    assert {%ScheduleRun{status: "failed", error: ~s(the condition "change" is not registered)},
            _} =
             run(schedule)
  end
end
