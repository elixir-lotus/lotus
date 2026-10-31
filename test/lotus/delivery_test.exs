defmodule Lotus.DeliveryTest do
  @moduledoc """
  Deliveries: the formats a run is rendered in, the webhook channel, channels
  a host registers, and how the worker records and retries them.
  """
  use Lotus.Case, async: false
  use Mimic

  import Lotus.Fixtures

  alias Lotus.{Config, Delivery, Result, Schedules}
  alias Lotus.Delivery.Channels.{Email, Slack, Webhook}
  alias Lotus.Delivery.Content
  alias Lotus.Delivery.Formats.{CSV, HTML, JSON}
  alias Lotus.Scheduler.Worker
  alias Lotus.Storage.ScheduleRun

  defmodule TestMailer do
    @moduledoc false
    use Swoosh.Mailer, otp_app: :lotus, adapter: Swoosh.Adapters.Test
  end

  defmodule DownMailer do
    @moduledoc false
    def deliver(_email), do: {:error, {401, "the API key is not valid"}}
  end

  defmodule PigeonChannel do
    @moduledoc false
    @behaviour Lotus.Delivery.Channel
    def formats, do: :any
    def label, do: "Carrier pigeon"
    def settings, do: [%{key: "loft", label: "Loft", type: :text, required: true}]
    def available, do: {:error, "the pigeons are not set up"}
    def validate_config(_config), do: :ok
    def deliver(_content, _attachments, _config), do: :ok
  end

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
        channels: %{"send" => SendChannel, "pigeon" => PigeonChannel},
        webhook: [req_options: [plug: {Req.Test, __MODULE__}]] ++ extra,
        slack: [req_options: [plug: {Req.Test, __MODULE__}]],
        email: [mailer: TestMailer, from: {"Lotus", "reports@example.com"}]
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

  defp spec(name), do: Enum.find(Delivery.channel_specs(), &(&1.name == name))

  describe "channel_specs/0" do
    setup do
      delivery_config()
      :ok
    end

    test "says each channel as an editor draws it, sorted by label" do
      assert ["Carrier pigeon", "Email", "send", "Slack", "Webhook"] =
               Enum.map(Delivery.channel_specs(), & &1.label)

      assert %{
               label: "Webhook",
               available: :ok,
               formats: ["csv", "html", "json"],
               settings: [
                 %{key: "url", type: :url, required: true},
                 %{key: "authorization", type: :secret}
               ]
             } = spec("webhook")
    end

    test "a channel without the optional callbacks: its name, no fields, available" do
      assert %{label: "send", settings: nil, available: :ok, formats: ["csv"]} = spec("send")
    end

    test "a run's delivery to a channel that is not available fails with its reason" do
      delivery = %{id: "d1", channel: "pigeon", format: "csv", config: %{}}

      assert %{"d1" => %{"status" => "failed", "error" => "the pigeons are not set up"}} =
               Delivery.deliver_all(content([result("Revenue", ["n"], [[1]])]), [delivery])
    end

    test "says a channel that is not available, and why" do
      assert %{available: {:error, "the pigeons are not set up"}, settings: [%{key: "loft"}]} =
               spec("pigeon")
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

    test "without Req, the webhook is not available, and a delivery to it is refused" do
      Application.put_env(:lotus, :__req_dependency__, Lotus.DeliveryTest.NoReq)
      on_exit(fn -> Application.delete_env(:lotus, :__req_dependency__) end)

      assert {:error, :channel, message} =
               Delivery.validate("webhook", "csv", %{"url" => "https://x.io"})

      assert message =~ ~s({:req, "~> 0.5"})
      assert %{available: {:error, ^message}} = spec("webhook")
    end

    test "a channel that is not available is refused, with its reason" do
      assert {:error, :channel, "the pigeons are not set up"} =
               Delivery.validate("pigeon", "csv", %{})
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

    test "sends the authorization setting as the authorization header" do
      pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{})
      end)

      assert :ok =
               Webhook.deliver(content([]), [], %{
                 "url" => "https://hooks.example.com/lotus",
                 "authorization" => "Bearer s3cret"
               })

      assert_received {:authorization, ["Bearer s3cret"]}

      assert :ok =
               Delivery.validate("webhook", "csv", %{
                 "url" => "https://x.io",
                 "authorization" => "t"
               })

      assert {:error, :config, "the authorization must be a string"} =
               Delivery.validate("webhook", "csv", %{
                 "url" => "https://x.io",
                 "authorization" => 1
               })
    end

    test "refuses an authorization or header value a header can't hold, without quoting it" do
      for config <- [
            %{"url" => "https://x.io", "authorization" => "Bearer DUMMY-token\n"},
            %{"url" => "https://x.io", "headers" => %{"x-api-key" => "DUMMY-token\r"}},
            %{"url" => "https://x.io", "headers" => %{"x-api-key" => "DUMMY-tökén"}}
          ] do
        assert {:error, :config, message} = Delivery.validate("webhook", "csv", config)
        assert message =~ "a header can't hold"
        refute message =~ "DUMMY"
      end

      assert :ok =
               Delivery.validate("webhook", "csv", %{
                 "url" => "https://x.io",
                 "authorization" => "Bearer a.b-c_d~e+f/g=\th",
                 "headers" => %{"x-api-key" => "k 1"}
               })
    end

    test "a response that is not 2xx is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)

      assert {:error, "the webhook answered 503: busy"} =
               Webhook.deliver(content([]), [], %{"url" => "https://x.io"})
    end
  end

  describe "the Slack channel" do
    setup do
      delivery_config()
      :ok
    end

    @hook "https://hooks.slack.com/services/T000/B000/XXXX"

    test "takes only a Slack incoming webhook's URL" do
      assert :ok = Delivery.validate("slack", "csv", %{"webhook_url" => @hook})

      assert {:error, :config, "a Slack delivery needs the incoming webhook's URL"} =
               Delivery.validate("slack", "csv", %{})

      for url <- [
            "https://example.com/hook",
            "http://hooks.slack.com/services/x",
            "hooks.slack.com"
          ] do
        assert {:error, :config, "the URL must be a Slack incoming webhook's" <> _} =
                 Delivery.validate("slack", "csv", %{"webhook_url" => url})
      end

      assert %{label: "Slack", available: :ok, settings: [%{key: "webhook_url", type: :secret}]} =
               spec("slack")
    end

    test "posts the results as a message with a table of the first rows" do
      pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(pid, {:slack, conn.request_path, Lotus.JSON.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      rows = for n <- 1..12, do: ["north <#{n}>", n * 10]
      content = content([result("Revenue & costs", ["region", "total"], rows)])

      assert :ok = Slack.deliver(content, [], %{"webhook_url" => @hook})
      assert_received {:slack, "/services/T000/B000/XXXX", message}

      assert %{
               "text" => "Weekly <revenue>",
               "blocks" => [
                 %{"type" => "header", "text" => %{"text" => "Weekly <revenue>"}},
                 %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => table}},
                 %{"type" => "context"}
               ]
             } = message

      assert table =~ "*Revenue &amp; costs* · the first 10 of 12 rows"
      assert table =~ "region      total"
      assert table =~ "north &lt;1&gt;   10\nnorth &lt;2&gt;   20"
      refute table =~ "north &lt;11&gt;"
    end

    test "an alert says it fired or recovered" do
      content = %{
        content([])
        | alert: %{status: "firing", value: 12, message: "total is above 10"}
      }

      assert %{"text" => "Weekly <revenue>: total is above 10", "blocks" => [_header, alert | _]} =
               Slack.message(content)

      assert alert["text"]["text"] =~ ":rotating_light: *Alert*: total is above 10"

      recovered = %{content | alert: %{status: "ok", value: 3, message: "total is back under 10"}}

      assert %{"text" => "Weekly <revenue> recovered: total is back under 10"} =
               Slack.message(recovered)
    end

    test "keeps a long result under Slack's limits, and says the results it leaves out" do
      wide = for n <- 1..10, do: Enum.map(1..30, &"#{&1}-#{String.duplicate("x", 40)}-#{n}")
      columns = Enum.map(1..30, &"c#{&1}")

      content =
        content(for n <- 1..5, do: result("Result #{n}", columns, wide))

      %{"blocks" => blocks} = Slack.message(content)

      sections = Enum.filter(blocks, &(&1["type"] == "section"))
      assert length(sections) == 3
      assert Enum.all?(sections, &(String.length(&1["text"]["text"]) <= 3000))
      assert Enum.all?(sections, &String.ends_with?(&1["text"]["text"], "```"))

      assert Enum.any?(
               blocks,
               &(&1["type"] == "context" and hd(&1["elements"])["text"] =~ "and 2 more results")
             )
    end

    test "an answer that is not 2xx is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "no_service") end)

      assert {:error, "Slack answered 404: no_service"} =
               Slack.deliver(content([]), [], %{"webhook_url" => @hook})
    end

    test "without Req, Slack is not available" do
      Application.put_env(:lotus, :__req_dependency__, Lotus.DeliveryTest.NoReq)
      on_exit(fn -> Application.delete_env(:lotus, :__req_dependency__) end)

      assert %{available: {:error, message}} = spec("slack")
      assert message =~ "the slack channel needs Req"
    end
  end

  defp email_config(email) do
    stub(Config, :delivery, fn -> [email: email] end)
  end

  describe "the email channel" do
    setup do
      delivery_config()
      :ok
    end

    test "sends through the app's mailer, with the format attached" do
      rows = for n <- 1..25, do: ["north <#{n}>", n]
      content = content([result("Revenue", ["region", "total"], rows)])
      {:ok, files} = CSV.render(content)

      assert :ok =
               Email.deliver(content, files, %{
                 "to" => ["team@example.com", " ops@example.com ", "team@example.com"],
                 "subject" => "Monday numbers"
               })

      assert_received {:email, email}

      assert email.from == {"Lotus", "reports@example.com"}
      assert email.to == [{"", "team@example.com"}, {"", "ops@example.com"}]
      assert email.subject == "Monday numbers"
      assert [%{filename: "revenue.csv", content_type: "text/csv"}] = email.attachments
      assert email.html_body =~ "north &lt;1&gt;"
      assert email.html_body =~ "the first 20 of 25 rows"
      refute email.html_body =~ "north &lt;21&gt;"
      assert email.text_body =~ "region | total"
    end

    test "a title with a line break makes a one-line subject" do
      content = %{content([]) | title: "Weekly\r\nBcc: dummy@example.invalid\n"}

      assert :ok = Email.deliver(content, [], %{"to" => ["team@example.com"]})

      assert_received {:email, email}
      assert email.subject == "Weekly Bcc: dummy@example.invalid"
      assert email.bcc == []
    end

    test "an alert's subject says it fired or recovered" do
      content = %{
        content([])
        | alert: %{status: "firing", value: 12, message: "total is above 10"}
      }

      assert :ok = Email.deliver(content, [], %{"to" => ["team@example.com"]})
      assert_received {:email, %{subject: "[Alert] Weekly <revenue>", html_body: html}}
      assert html =~ "total is above 10"

      recovered = %{content | alert: %{status: "ok", value: 3, message: "back under 10"}}
      assert :ok = Email.deliver(recovered, [], %{"to" => ["team@example.com"]})
      assert_received {:email, %{subject: "[Recovered] Weekly <revenue>"}}
    end

    test "leaves out attachments over the limit, and says so" do
      email_config(mailer: TestMailer, from: "reports@example.com", max_attachment_bytes: 10)
      {:ok, files} = CSV.render(content([result("Revenue", ["n"], [[123_456_789_012]])]))

      assert :ok = Email.deliver(content([]), files, %{"to" => ["team@example.com"]})
      assert_received {:email, %{attachments: [], html_body: html, text_body: text}}
      assert html =~ "was left out"
      assert text =~ "was left out"
    end

    test "checks the recipients and the subject" do
      ok = %{"to" => ["team@example.com"]}
      assert :ok = Delivery.validate("email", "csv", ok)

      for {config, message} <- [
            {%{}, "an email needs one recipient at least"},
            {%{"to" => [" "]}, "an email needs one recipient at least"},
            {%{"to" => "team@example.com"}, "the recipients must be a list of addresses"},
            {%{"to" => ["not an address"]}, ~s("not an address" is not an email address)},
            {%{"to" => for(n <- 1..51, do: "p#{n}@example.com")},
             "an email takes 50 recipients at most"},
            {Map.put(ok, "subject", "two\nlines"), "the subject must be one line"},
            {Map.put(ok, "subject", String.duplicate("x", 201)),
             "the subject takes 200 characters at most"}
          ] do
        assert {:error, :config, ^message} = Delivery.validate("email", "csv", config)
      end
    end

    test "a mailer that fails is the delivery's failure, with its reason" do
      email_config(mailer: DownMailer, from: "reports@example.com")

      assert {:error, "the mailer could not send it: the API key is not valid"} =
               Email.deliver(content([]), [], %{"to" => ["team@example.com"]})
    end

    test "is not available until the app names its mailer and from address" do
      for {settings, message} <- [
            {[], "email is not set up: name your app's mailer"},
            {[mailer: TestMailer], "email is not set up: give the address it is sent from"},
            {[mailer: NoSuchMailer, from: "r@example.com"],
             "the email mailer NoSuchMailer is not a module with deliver/1"},
            {[mailer: TestMailer, from: "nope"],
             ~s(the email from address is not an address: "nope")}
          ] do
        email_config(settings)
        assert {:error, got} = Email.available()
        assert got =~ message

        assert {:error, :channel, ^got} =
                 Delivery.validate("email", "csv", %{"to" => ["a@example.com"]})
      end
    end

    test "without Swoosh, email is not available" do
      Application.put_env(:lotus, :__swoosh_dependency__, Lotus.DeliveryTest.NoSwoosh)
      on_exit(fn -> Application.delete_env(:lotus, :__swoosh_dependency__) end)

      assert %{available: {:error, message}} = spec("email")
      assert message =~ ~s({:swoosh, "~> 1.16"})
    end

    test "an app that set email up but cannot send is told why when it starts" do
      email_config(mailer: TestMailer)

      log = ExUnit.CaptureLog.capture_log(fn -> Email.warn_if_misconfigured() end)
      assert log =~ "Lotus email deliveries cannot be sent: email is not set up"

      email_config([])
      assert ExUnit.CaptureLog.capture_log(fn -> Email.warn_if_misconfigured() end) == ""
    end
  end

  describe "send_test/4" do
    setup do
      delivery_config()
      :ok
    end

    test "sends sample results to a delivery, now" do
      assert :ok = Delivery.send_test("send", "csv", %{"to" => "ops"}, title: "Weekly revenue")

      assert_received {:delivered, "ops", "Test: Weekly revenue",
                       [%{filename: filename, body: body}]}

      assert filename =~ ".csv"
      assert IO.iodata_to_binary(body) =~ "North,1200"
    end

    test "as an alert, to see how one looks" do
      assert :ok = Delivery.send_test("email", "csv", %{"to" => ["a@example.com"]}, alert: true)
      assert_received {:email, %{subject: "[Alert] Test: a Lotus report", attachments: [_csv]}}
    end

    test "says what is wrong before sending anything" do
      assert {:error, "needs a recipient"} = Delivery.send_test("send", "csv", %{})
      assert {:error, "the pigeons are not set up"} = Delivery.send_test("pigeon", "csv", %{})
      assert {:error, "is not a known channel: \"nope\""} = Delivery.send_test("nope", "csv", %{})
      refute_received {:delivered, _, _, _}
    end

    test "says the channel's reason when it fails" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "bad token") end)

      assert {:error, "the webhook answered 401: bad token"} =
               Delivery.send_test("webhook", "json", %{"url" => "https://hooks.example.com/x"})
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

    test "no schedule or delivery event carries a delivery's secret settings", %{query: query} do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{}))
      ref = make_ref()
      pid = self()

      events =
        for prefix <- [
              [:lotus, :content, :change],
              [:lotus, :schedule, :run],
              [:lotus, :delivery]
            ],
            suffix <- [:start, :stop, :exception],
            do: prefix ++ [suffix]

      :telemetry.attach_many(
        "#{inspect(ref)}",
        events,
        fn event, _measurements, metadata, _ -> send(pid, {:event, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      {schedule, run} =
        schedule_with(query, [
          %{
            channel: "webhook",
            format: "csv",
            config: %{
              "url" => "https://x.io/hook",
              "authorization" => "Bearer DUMMY-TOKEN",
              "headers" => %{"x-api-key" => "DUMMY-KEY"}
            }
          },
          %{
            channel: "slack",
            format: "csv",
            config: %{"webhook_url" => "https://hooks.slack.com/services/T0/B0/DUMMY-PATH"}
          }
        ])

      {:ok, _} = Schedules.update_schedule(schedule, %{name: "Weekly, renamed"})
      assert {:ok, _} = Worker.perform(run.id)

      received = collect_events([])
      seen = received |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      assert [:lotus, :content, :change, :stop] in seen
      assert [:lotus, :schedule, :run, :stop] in seen
      assert [:lotus, :delivery, :stop] in seen

      for {event, metadata} <- received do
        refute inspect(metadata, limit: :infinity) =~ "DUMMY", inspect(event)
      end

      assert Enum.any?(received, fn {_event, metadata} ->
               inspect(metadata, limit: :infinity) =~ "https://x.io/hook"
             end)
    end

    defp collect_events(acc) do
      receive do
        {:event, event, metadata} -> collect_events([{event, metadata} | acc])
      after
        0 -> acc
      end
    end
  end
end
