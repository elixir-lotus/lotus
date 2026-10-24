defmodule Lotus.DeliveryTest do
  @moduledoc """
  Deliveries: the formats a run is rendered in, the webhook channel, channels
  a host registers, and how the worker records and retries them.
  """
  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Config, Delivery, Result, Schedules}
  alias Lotus.Delivery.Channels.Webhook
  alias Lotus.Delivery.Content
  alias Lotus.Delivery.Formats.{CSV, HTML, JSON}
  alias Lotus.Scheduler.Worker
  alias Lotus.Storage.ScheduleRun

  defmodule SendChannel do
    @moduledoc false
    @behaviour Lotus.Delivery.Channel
    def formats, do: ["csv"]
    def validate_config(%{"to" => to}) when is_binary(to), do: :ok
    def validate_config(_config), do: {:error, "needs a recipient"}

    def deliver(content, attachments, config) do
      send(self(), {:delivered, config["to"], content.title, attachments})
      :ok
    end
  end

  defp content(results) do
    %Content{
      title: "Weekly <revenue>",
      results: results,
      schedule: %Lotus.Storage.Schedule{id: 7, name: "Weekly <revenue>"},
      run: %ScheduleRun{id: 42, scheduled_for: ~U[2026-10-26 08:00:00.000000Z]}
    }
  end

  defp result(title, columns, rows), do: %{title: title, result: Result.new(columns, rows)}

  defp delivery_config(extra \\ []) do
    stub(Config, :delivery, fn ->
      [
        channels: %{"send" => SendChannel},
        webhook: [req_options: [plug: {Req.Test, __MODULE__}]] ++ extra
      ]
    end)
  end

  describe "formats" do
    test "CSV is a file per result, with names that don't clash" do
      {:ok, files} =
        CSV.render(
          content([
            result("Revenue", ["region", "total"], [["north", 120]]),
            result("Revenue", ["n"], [[1]])
          ])
        )

      assert [
               %{filename: "revenue.csv", content_type: "text/csv", body: body},
               %{filename: "revenue_2.csv"}
             ] = files

      assert IO.iodata_to_binary(body) == "region,total\nnorth,120\n"
    end

    test "JSON is one file with every result" do
      {:ok, [%{filename: "weekly_revenue.json", body: body}]} =
        JSON.render(content([result("Revenue", ["region", "total"], [["north", 120]])]))

      assert Lotus.JSON.decode!(body) == %{
               "title" => "Weekly <revenue>",
               "results" => [
                 %{
                   "title" => "Revenue",
                   "columns" => ["region", "total"],
                   "rows" => [["north", 120]]
                 }
               ]
             }
    end

    test "HTML is one document with a table per result, every value escaped" do
      {:ok, [%{filename: "weekly_revenue.html", body: body}]} =
        HTML.render(content([result("A & B", ["<col>"], [["<script>x</script>"]])]))

      html = IO.iodata_to_binary(body)
      assert html =~ "<h1>Weekly &lt;revenue&gt;</h1>"
      assert html =~ "<h2>A &amp; B</h2>"
      assert html =~ "<th>&lt;col&gt;</th>"
      assert html =~ "<td>&lt;script&gt;x&lt;/script&gt;</td>"
      refute html =~ "<script>"
    end
  end

  describe "validate/3" do
    setup do
      delivery_config()
      :ok
    end

    test "a known channel, a known format it sends, and settings it accepts" do
      assert :ok = Delivery.validate("webhook", "csv", %{"url" => "https://hooks.example.com/x"})
      assert {:error, :channel, _} = Delivery.validate("pigeon", "csv", %{})

      assert {:error, :format, _} =
               Delivery.validate("webhook", "pdf", %{"url" => "https://x.io"})

      assert {:error, :format, "send does not send json"} =
               Delivery.validate("send", "json", %{"to" => "a"})

      assert {:error, :config, "needs a recipient"} = Delivery.validate("send", "csv", %{})
    end

    test "a webhook needs an https url, unless http is allowed" do
      assert {:error, :config, "a webhook needs a url"} = Delivery.validate("webhook", "csv", %{})

      assert {:error, :config, "the url must be https"} =
               Delivery.validate("webhook", "csv", %{"url" => "http://hooks.example.com"})

      assert {:error, :config, _} = Delivery.validate("webhook", "csv", %{"url" => "ftp://x"})

      assert {:error, :config, "headers must map names to strings"} =
               Delivery.validate("webhook", "csv", %{
                 "url" => "https://x.io",
                 "headers" => %{"a" => 1}
               })

      delivery_config(allow_http: true)
      assert :ok = Delivery.validate("webhook", "csv", %{"url" => "http://hooks.internal"})
    end

    test "without Req, a webhook delivery is refused" do
      Application.put_env(:lotus, :__req_dependency__, Lotus.DeliveryTest.NoReq)
      on_exit(fn -> Application.delete_env(:lotus, :__req_dependency__) end)

      assert {:error, :config, message} =
               Delivery.validate("webhook", "csv", %{"url" => "https://x.io"})

      assert message =~ ~s({:req, "~> 0.5"})
    end

    test "a schedule refuses a delivery that does not validate" do
      query = query_fixture()

      assert {:error, changeset} =
               Schedules.create_schedule(%{
                 name: "x",
                 query_id: query.id,
                 cron: "0 8 * * *",
                 deliveries: [%{channel: "webhook", format: "csv", config: %{}}]
               })

      assert %{deliveries: [%{config: ["a webhook needs a url"]}]} = errors_on(changeset)
    end
  end

  describe "the webhook channel" do
    setup do
      delivery_config()
      :ok
    end

    test "POSTs the attachments as JSON, with the configured headers" do
      pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(pid, {:webhook, conn.method, Plug.Conn.get_req_header(conn, "authorization"), body})
        Req.Test.json(conn, %{"ok" => true})
      end)

      {:ok, files} = CSV.render(content([result("Revenue", ["n"], [[1]])]))

      assert :ok =
               Webhook.deliver(content([]), files, %{
                 "url" => "https://hooks.example.com/lotus",
                 "headers" => %{"authorization" => "Bearer t0ken"}
               })

      assert_received {:webhook, "POST", ["Bearer t0ken"], body}

      assert %{
               "title" => "Weekly <revenue>",
               "schedule" => %{"id" => 7},
               "run" => %{"id" => 42, "scheduled_for" => "2026-10-26T08:00:00.000000Z"},
               "attachments" => [
                 %{
                   "filename" => "revenue.csv",
                   "content_type" => "text/csv",
                   "content" => "n\n1\n"
                 }
               ]
             } = Lotus.JSON.decode!(body)
    end

    test "a response that is not 2xx is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)

      assert {:error, "the webhook answered 503: busy"} =
               Webhook.deliver(content([]), [], %{"url" => "https://x.io"})
    end
  end

  describe "a run with deliveries" do
    setup do
      delivery_config()
      stub(Config, :scheduler, fn -> [] end)
      query = query_fixture(%{name: "Revenue", statement: "SELECT 1 AS n"})
      %{query: query}
    end

    defp schedule_with(query, deliveries) do
      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "Weekly",
          query_id: query.id,
          cron: "0 8 * * MON",
          deliveries: deliveries
        })

      {:ok, run} =
        schedule.id
        |> ScheduleRun.claim_changeset(~U[2026-10-26 08:00:00.000000Z])
        |> Repo.insert()

      {schedule, run}
    end

    test "each delivery is sent and recorded on the run", %{query: query} do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))

      {schedule, run} =
        schedule_with(query, [
          %{channel: "send", format: "csv", config: %{"to" => "ops"}},
          %{channel: "webhook", format: "json", config: %{"url" => "https://x.io"}}
        ])

      [send_delivery, webhook_delivery] = schedule.deliveries

      assert {:ok, %ScheduleRun{status: "succeeded", details: %{"deliveries" => outcomes}}} =
               Worker.perform(run.id)

      assert outcomes == %{
               send_delivery.id => %{"status" => "delivered"},
               webhook_delivery.id => %{"status" => "delivered"}
             }

      assert_received {:delivered, "ops", "Weekly", [%{filename: "revenue.csv"}]}
    end

    test "a failed delivery fails the run; a retry sends only what failed", %{query: query} do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))

      {schedule, run} =
        schedule_with(query, [
          %{channel: "send", format: "csv", config: %{"to" => "ops"}},
          %{channel: "webhook", format: "csv", config: %{"url" => "https://x.io"}}
        ])

      [_send, webhook] = schedule.deliveries

      assert {:ok,
              %ScheduleRun{status: "failed", error: "1 of 2 deliveries failed", details: details}} =
               Worker.perform(run.id)

      assert %{"status" => "failed", "error" => "the webhook answered 500: down"} =
               details["deliveries"][webhook.id]

      assert_received {:delivered, "ops", _, _}

      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))

      assert {:ok, %ScheduleRun{status: "succeeded"}} = Worker.perform(run.id, retry: true)
      refute_received {:delivered, _, _, _}
    end

    test "delivery telemetry brackets each delivery", %{query: query} do
      ref = make_ref()
      pid = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:lotus, :delivery, :stop]],
        fn event, _measurements, metadata, _ -> send(pid, {event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      {_schedule, run} =
        schedule_with(query, [%{channel: "send", format: "csv", config: %{"to" => "a"}}])

      assert {:ok, _} = Worker.perform(run.id)

      assert_received {[:lotus, :delivery, :stop], %{delivery: %{channel: "send", format: "csv"}}}
    end
  end
end
