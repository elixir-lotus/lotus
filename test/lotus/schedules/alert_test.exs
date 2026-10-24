defmodule Lotus.Schedules.AlertTest do
  @moduledoc """
  Alerts: reading the value and checking the rule (`Lotus.Schedules.Alert`),
  the rule on a schedule, and runs that send only when the status changes.
  """
  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Config, Result, Schedules}
  alias Lotus.Delivery.Formats.JSON
  alias Lotus.Scheduler.Worker
  alias Lotus.Schedules.Alert
  alias Lotus.Storage.{Query, Schedule, ScheduleRule, ScheduleRun}

  defmodule SendChannel do
    @moduledoc false
    @behaviour Lotus.Delivery.Channel
    def formats, do: :any
    def validate_config(_config), do: :ok

    def deliver(content, attachments, _config) do
      send(self(), {:delivered, content.alert, attachments})
      :ok
    end
  end

  defp rule(attrs), do: struct(ScheduleRule, attrs)

  describe "evaluate/2" do
    test "compares a column of the first row with the threshold" do
      result = Result.new(["region", "open"], [["north", 512], ["south", 3]])
      threshold = Decimal.new(500)

      assert {:ok, true, 512} =
               Alert.evaluate(
                 rule(condition: "above", column: "open", threshold: threshold),
                 result
               )

      assert {:ok, false, 512} =
               Alert.evaluate(
                 rule(condition: "below", column: "open", threshold: threshold),
                 result
               )

      assert {:ok, true, 512} =
               Alert.evaluate(
                 rule(condition: "equals", column: "open", threshold: Decimal.new(512)),
                 result
               )
    end

    test "without a column, compares the row count" do
      result = Result.new(["n"], [[1], [2], [3]])

      assert {:ok, true, 3} =
               Alert.evaluate(rule(condition: "above", threshold: Decimal.new(2)), result)
    end

    test "reads decimals, floats and numeric strings" do
      threshold = Decimal.new("0.5")
      above = rule(condition: "above", column: "v", threshold: threshold)

      assert {:ok, true, _} = Alert.evaluate(above, Result.new(["v"], [[Decimal.new("0.75")]]))
      assert {:ok, false, _} = Alert.evaluate(above, Result.new(["v"], [[0.25]]))
      assert {:ok, true, " 1.5 "} = Alert.evaluate(above, Result.new(["v"], [[" 1.5 "]]))
    end

    test "any_rows and no_rows read the row count" do
      none = Result.new(["id"], [])
      some = Result.new(["id"], [[1], [2]])

      assert {:ok, false, 0} = Alert.evaluate(rule(condition: "any_rows"), none)
      assert {:ok, true, 2} = Alert.evaluate(rule(condition: "any_rows"), some)
      assert {:ok, true, 0} = Alert.evaluate(rule(condition: "no_rows"), none)
    end

    test "a value it cannot read is an error" do
      above = rule(condition: "above", column: "open", threshold: Decimal.new(1))

      assert {:error, ~s(the result has no column "open")} =
               Alert.evaluate(above, Result.new(["n"], [[1]]))

      assert {:error, ~s(the query returned no rows to read "open" from)} =
               Alert.evaluate(above, Result.new(["open"], []))

      assert {:error, "open is empty"} = Alert.evaluate(above, Result.new(["open"], [[nil]]))

      assert {:error, ~s(open is not a number: "many")} =
               Alert.evaluate(above, Result.new(["open"], [["many"]]))
    end
  end

  test "describe/3 says what happened" do
    above = rule(condition: "above", column: "open", threshold: Decimal.new(500))
    assert Alert.describe(above, "firing", 512) == "open is 512, above 500"
    assert Alert.describe(above, "ok", 480) == "open is 480, no longer above 500"

    below = rule(condition: "below", threshold: Decimal.new("0.5"))
    assert Alert.describe(below, "firing", 0) == "the row count is 0, below 0.5"

    assert Alert.describe(rule(condition: "any_rows"), "firing", 1) ==
             "the query returned 1 row"

    assert Alert.describe(rule(condition: "no_rows"), "ok", 3) == "the query returned 3 rows"
  end

  describe "the rule of a schedule" do
    setup do
      %{query: query_fixture(%{statement: "SELECT 1 AS n"})}
    end

    test "is validated, and watches a query", %{query: query} do
      assert {:error, changeset} =
               Schedules.create_schedule(%{
                 name: "x",
                 query_id: query.id,
                 cron: "* * * * *",
                 rule: %{condition: "above"}
               })

      assert %{rule: %{threshold: ["can't be blank"]}} = errors_on(changeset)

      assert {:error, changeset} =
               Schedules.create_schedule(%{
                 name: "x",
                 query_id: query.id,
                 cron: "* * * * *",
                 rule: %{condition: "rising"}
               })

      assert %{rule: %{condition: ["is invalid"]}} = errors_on(changeset)

      dashboard = dashboard_fixture()

      assert {:error, changeset} =
               Schedules.create_schedule(%{
                 name: "x",
                 dashboard_id: dashboard.id,
                 cron: "* * * * *",
                 rule: %{condition: "any_rows"}
               })

      assert %{rule: ["an alert watches a query, not a dashboard"]} = errors_on(changeset)
    end

    test "is stored, and a new rule starts the state over", %{query: query} do
      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "x",
          query_id: query.id,
          cron: "* * * * *",
          rule: %{condition: "above", column: "n", threshold: "2.5"}
        })

      assert %ScheduleRule{condition: "above", threshold: threshold, notify_recovery: true} =
               Schedules.get_schedule!(schedule.id).rule

      assert Decimal.equal?(threshold, Decimal.new("2.5"))

      Repo.update_all(from(s in Schedule, where: s.id == ^schedule.id),
        set: [state: %{"status" => "firing"}]
      )

      schedule = Schedules.get_schedule!(schedule.id)
      {:ok, schedule} = Schedules.update_schedule(schedule, %{name: "y"})
      assert %{"status" => "firing"} = Schedules.get_schedule!(schedule.id).state

      {:ok, schedule} =
        Schedules.update_schedule(schedule, %{rule: %{condition: "any_rows"}})

      assert Schedules.get_schedule!(schedule.id).state == %{}

      {:ok, schedule} = Schedules.update_schedule(schedule, %{rule: nil})
      assert Schedules.get_schedule!(schedule.id).rule == nil
    end
  end

  describe "a run of an alert" do
    setup do
      stub(Config, :scheduler, fn -> [] end)

      stub(Config, :delivery, fn ->
        [
          channels: %{"send" => SendChannel},
          webhook: [req_options: [plug: {Req.Test, __MODULE__}]]
        ]
      end)

      query = query_fixture(%{name: "Open tickets", statement: "SELECT 512 AS open"})
      %{query: query}
    end

    defp alert(query, rule, deliveries \\ [%{channel: "send", format: "json", config: %{}}]) do
      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "Open tickets",
          query_id: query.id,
          cron: "*/15 * * * *",
          rule: rule,
          deliveries: deliveries
        })

      schedule
    end

    defp returns(query, statement) do
      Repo.update_all(from(q in Query, where: q.id == ^query.id), set: [statement: statement])
    end

    defp run(schedule, opts \\ []) do
      {:ok, run} =
        schedule.id
        |> ScheduleRun.claim_changeset(DateTime.utc_now())
        |> Repo.insert()

      {:ok, run} = Worker.perform(run.id, opts)
      {run, Schedules.get_schedule!(schedule.id).state}
    end

    test "sends when it starts firing and when it recovers, not while it stays", %{query: query} do
      schedule = alert(query, %{condition: "above", column: "open", threshold: 500})

      assert {%ScheduleRun{status: "succeeded", details: %{"alert" => alert}},
              %{"status" => "firing", "value" => 512, "fired_at" => _}} = run(schedule)

      assert alert == %{"status" => "firing", "value" => 512, "change" => "firing"}

      assert_received {:delivered, %{status: "firing", value: 512, message: message},
                       [%{body: body}]}

      assert message == "open is 512, above 500"

      assert %{"alert" => %{"status" => "firing", "message" => "open is 512, above 500"}} =
               Lotus.JSON.decode!(body)

      assert {%ScheduleRun{status: "succeeded", details: %{"alert" => %{"change" => nil}}},
              %{"status" => "firing"}} = run(schedule)

      refute_received {:delivered, _, _}

      returns(query, "SELECT 480 AS open")

      assert {%ScheduleRun{status: "succeeded"},
              %{"status" => "ok", "value" => 480, "fired_at" => _, "recovered_at" => _}} =
               run(schedule)

      assert_received {:delivered, %{status: "ok", message: "open is 480, no longer above 500"},
                       _}
    end

    test "without notify_recovery, recovering sends nothing", %{query: query} do
      schedule =
        alert(query, %{
          condition: "above",
          column: "open",
          threshold: 500,
          notify_recovery: false
        })

      run(schedule)
      assert_received {:delivered, %{status: "firing"}, _}

      returns(query, "SELECT 1 AS open")
      assert {_run, %{"status" => "ok"}} = run(schedule)
      refute_received {:delivered, _, _}
    end

    test "a run that cannot read the value keeps the status and records the error", %{
      query: query
    } do
      schedule = alert(query, %{condition: "above", column: "open", threshold: 500})
      run(schedule)
      assert_received {:delivered, %{status: "firing"}, _}

      returns(query, "SELECT 'many' AS open")

      assert {%ScheduleRun{status: "failed", error: ~s(open is not a number: "many")},
              %{"status" => "firing", "error" => _, "errored_at" => _}} = run(schedule)

      returns(query, "SELECT * FROM no_such_table")

      assert {%ScheduleRun{status: "failed"}, %{"status" => "firing", "error" => error}} =
               run(schedule)

      assert error =~ "no_such_table"

      returns(query, "SELECT 600 AS open")
      assert {%ScheduleRun{status: "succeeded"}, state} = run(schedule)
      assert %{"status" => "firing", "value" => 600} = state
      refute Map.has_key?(state, "error")
      refute_received {:delivered, _, _}
    end

    test "a change whose deliveries failed is sent again", %{query: query} do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))

      schedule =
        alert(query, %{condition: "any_rows"}, [
          %{channel: "webhook", format: "json", config: %{"url" => "https://x.io"}}
        ])

      assert {%ScheduleRun{status: "failed"} = failed, state} = run(schedule)
      assert state == %{}

      pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(pid, {:webhook, Lotus.JSON.decode!(body)})
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %ScheduleRun{status: "succeeded"}} = Worker.perform(failed.id, retry: true)
      assert %{"status" => "firing"} = Schedules.get_schedule!(schedule.id).state

      assert_received {:webhook,
                       %{
                         "alert" => %{
                           "status" => "firing",
                           "message" => "the query returned 1 row"
                         }
                       }}
    end
  end

  test "the JSON format leaves alert out for other schedules" do
    content = %Lotus.Delivery.Content{
      title: "x",
      results: [],
      schedule: %Schedule{id: 1, name: "x"},
      run: %ScheduleRun{id: 1}
    }

    {:ok, [%{body: body}]} = JSON.render(content)
    refute Map.has_key?(Lotus.JSON.decode!(body), "alert")
  end
end
