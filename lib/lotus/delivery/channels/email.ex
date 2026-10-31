defmodule Lotus.Delivery.Channels.Email do
  @moduledoc """
  The `"email"` channel: emails a run's results through your app's own
  [Swoosh](https://hex.pm/packages/swoosh) mailer.

      %{
        channel: "email",
        format: "csv",
        config: %{"to" => ["team@example.com"], "subject" => "Weekly revenue"}
      }

  Lotus sends nothing itself: it builds the email and hands it to your
  mailer, so it goes through the service your app already sends with
  (SMTP, Postmark, SES…), at its cost. In development, Swoosh's local
  adapter shows it in `/dev/mailbox`.

  ## Setting it up

  A Phoenix app has a mailer (`MyApp.Mailer`, from `mix phx.new`). Name it,
  and the address the emails come from:

      config :lotus,
        delivery: [
          email: [
            mailer: MyApp.Mailer,
            from: {"Lotus", "reports@example.com"},
            # optional: attachments over this size are left out (10 MB)
            max_attachment_bytes: 10_000_000
          ]
        ]

  Swoosh is an optional dependency of Lotus; a Phoenix app has it already.

  Without Swoosh, a `mailer`, or a `from`, or with a mailer that is not a
  module with `deliver/1`, the channel is not available (`available/0`
  says what is missing): it is not offered, a schedule that delivers by
  email is refused when it is saved, and a run's email fails with the
  same message (its other deliveries are sent). When the app starts with
  the `email` settings but the channel cannot send, Lotus logs why.

  ## The email

  The subject is the delivery's `"subject"`, or the schedule's name; an
  alert's starts with `[Alert]` or `[Recovered]`. The body has the alert's
  message and, for each result, its first rows (20 at most) as a table,
  every value escaped. The delivery's format is attached (a CSV file, for
  example); attachments larger than `max_attachment_bytes` in all are left
  out, and the body says so.

  A failure of the mailer (refused credentials, a provider down) is the
  run's failure, with the mailer's reason; with Oban, a retried run sends
  only the deliveries that failed.

  ## Recipients

  `"to"` is a list of addresses, one at least and 50 at most; each must
  look like an address (`name@domain`).
  """

  @behaviour Lotus.Delivery.Channel

  require Logger

  alias Lotus.Delivery.Formats.HTML

  @max_recipients 50
  @preview_rows 20
  @max_attachment_bytes 10_000_000
  @address ~r/^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/

  @impl true
  def formats, do: :any

  @impl true
  def label, do: "Email"

  @impl true
  def settings do
    [
      %{
        key: "to",
        label: "Recipients",
        type: :email_list,
        required: true,
        placeholder: "team@example.com",
        help: "Up to #{@max_recipients} addresses."
      },
      %{
        key: "subject",
        label: "Subject",
        type: :text,
        placeholder: "The report's name",
        help: "An alert's starts with [Alert] or [Recovered]."
      }
    ]
  end

  # Swoosh is optional: its modules are called through functions, so Lotus
  # compiles without it. The module an app without Swoosh does not have is
  # a setting only so that the tests can stand for such an app.
  defp swoosh, do: Application.get_env(:lotus, :__swoosh_dependency__, Swoosh.Email)

  defp attachment_module,
    do: Application.get_env(:lotus, :__swoosh_attachment__, Swoosh.Attachment)

  defp host_settings, do: Keyword.get(Lotus.Config.delivery(), :email, [])

  @impl true
  def available do
    settings = host_settings()

    with :ok <- ensure_swoosh(),
         {:ok, mailer} <- fetch_mailer(settings),
         :ok <- ensure_mailer(mailer) do
      validate_from(Keyword.get(settings, :from))
    end
  end

  defp ensure_swoosh do
    if Code.ensure_loaded?(swoosh()),
      do: :ok,
      else: {:error, ~s(the email channel needs Swoosh: add {:swoosh, "~> 1.16"} to your deps)}
  end

  defp fetch_mailer(settings) do
    case Keyword.get(settings, :mailer) do
      nil ->
        {:error,
         "email is not set up: name your app's mailer with config :lotus, delivery: [email: [mailer: MyApp.Mailer, from: ...]]"}

      mailer when is_atom(mailer) ->
        {:ok, mailer}

      other ->
        {:error, "the email mailer must be a module, got #{inspect(other)}"}
    end
  end

  defp ensure_mailer(mailer) do
    if Code.ensure_loaded?(mailer) and function_exported?(mailer, :deliver, 1),
      do: :ok,
      else: {:error, "the email mailer #{inspect(mailer)} is not a module with deliver/1"}
  end

  defp validate_from({name, address}) when is_binary(name) and is_binary(address),
    do: validate_from(address)

  defp validate_from(address) when is_binary(address) do
    if address?(address),
      do: :ok,
      else: {:error, "the email from address is not an address: #{inspect(address)}"}
  end

  defp validate_from(nil),
    do:
      {:error,
       "email is not set up: give the address it is sent from with config :lotus, delivery: [email: [from: \"reports@example.com\"]]"}

  defp validate_from(other),
    do: {:error, "the email from address is not an address: #{inspect(other)}"}

  @doc false
  # Logs why the email channel cannot send, for an app that set it up.
  def warn_if_misconfigured do
    with [_ | _] <- host_settings(),
         {:error, message} <- available() do
      Logger.warning("Lotus email deliveries cannot be sent: #{message}")
    end

    :ok
  end

  @impl true
  def validate_config(config) do
    with :ok <- available(),
         {:ok, _to} <- recipients(Map.get(config, "to")) do
      validate_subject(Map.get(config, "subject"))
    end
  end

  defp recipients(to) when is_list(to) do
    to = to |> Enum.map(&trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    cond do
      to == [] ->
        {:error, "an email needs one recipient at least"}

      length(to) > @max_recipients ->
        {:error, "an email takes #{@max_recipients} recipients at most"}

      bad = Enum.find(to, &(not address?(&1))) ->
        {:error, "#{inspect(bad)} is not an email address"}

      true ->
        {:ok, to}
    end
  end

  defp recipients(nil), do: {:error, "an email needs one recipient at least"}
  defp recipients(_to), do: {:error, "the recipients must be a list of addresses"}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp address?(value), do: is_binary(value) and Regex.match?(@address, value)

  defp validate_subject(nil), do: :ok

  defp validate_subject(subject) when is_binary(subject) do
    cond do
      String.length(subject) > 200 -> {:error, "the subject takes 200 characters at most"}
      String.contains?(subject, ["\r", "\n"]) -> {:error, "the subject must be one line"}
      true -> :ok
    end
  end

  defp validate_subject(_subject), do: {:error, "the subject must be text"}

  @impl true
  def deliver(content, attachments, config) do
    with :ok <- validate_config(config),
         {:ok, to} <- recipients(config["to"]) do
      settings = host_settings()
      mailer = Keyword.fetch!(settings, :mailer)
      max_bytes = Keyword.get(settings, :max_attachment_bytes, @max_attachment_bytes)
      {attachments, dropped} = fit_attachments(attachments, max_bytes)

      email =
        swoosh().new(
          from: Keyword.fetch!(settings, :from),
          to: to,
          subject: subject(content, config["subject"]),
          html_body: html_body(content, dropped, max_bytes),
          text_body: text_body(content, dropped, max_bytes)
        )

      email = Enum.reduce(attachments, email, &attach/2)

      case mailer.deliver(email) do
        {:ok, _meta} -> :ok
        {:error, reason} -> {:error, "the mailer could not send it: #{describe(reason)}"}
      end
    end
  end

  defp attach(attachment, email) do
    swoosh().attachment(
      email,
      attachment_module().new({:data, IO.iodata_to_binary(attachment.body)},
        filename: attachment.filename,
        content_type: attachment.content_type
      )
    )
  end

  # The attachments, unless together they are over the limit: then none,
  # and how large they were.
  defp fit_attachments(attachments, max_bytes) do
    bytes = attachments |> Enum.map(&IO.iodata_length(&1.body)) |> Enum.sum()
    if bytes > max_bytes, do: {[], bytes}, else: {attachments, nil}
  end

  # A subject is one header line. The configured one is checked when the
  # delivery is saved; the run's title (a schedule's name) is not, and some
  # mail encoders write a line break in it as is, so it is made one line.
  defp subject(content, subject) do
    base =
      case subject do
        subject when is_binary(subject) and subject != "" -> String.trim(subject)
        _ -> content.title |> to_string() |> String.replace(~r/[\r\n]+/, " ") |> String.trim()
      end

    case content.alert do
      %{status: "firing"} -> "[Alert] " <> base
      %{status: _ok} -> "[Recovered] " <> base
      nil -> base
    end
  end

  defp html_body(content, dropped, max_bytes) do
    [
      "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head>",
      "<body style=\"font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#111827\">",
      "<h2 style=\"margin:0 0 12px\">",
      HTML.escape(content.title),
      "</h2>",
      html_alert(content.alert),
      Enum.map(content.results, &html_result/1),
      html_dropped(dropped, max_bytes),
      "<p style=\"color:#6b7280;font-size:12px\">Sent by Lotus · ",
      HTML.escape(Calendar.strftime(content.run.scheduled_for, "%Y-%m-%d %H:%M UTC")),
      "</p></body></html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp html_alert(nil), do: []

  defp html_alert(%{status: status, message: message}) do
    {label, color} =
      if status == "firing", do: {"Alert", "#b91c1c"}, else: {"Recovered", "#15803d"}

    [
      "<p><strong style=\"color:",
      color,
      "\">",
      label,
      "</strong>: ",
      HTML.escape(message),
      "</p>"
    ]
  end

  defp html_result(%{title: title, result: result}) do
    rows = Enum.take(result.rows, @preview_rows)
    total = result.num_rows || length(result.rows)
    cell = "padding:4px 8px;border-bottom:1px solid #e5e7eb;text-align:left"

    [
      "<h3 style=\"margin:20px 0 6px\">",
      HTML.escape(title),
      "</h3><p style=\"margin:0 0 6px;color:#6b7280;font-size:12px\">",
      HTML.escape(count(length(rows), total)),
      "</p>",
      if rows == [] do
        []
      else
        [
          "<table style=\"border-collapse:collapse;font-size:13px\"><thead><tr>",
          Enum.map(result.columns, &["<th style=\"", cell, "\">", HTML.escape(&1), "</th>"]),
          "</tr></thead><tbody>",
          Enum.map(rows, fn row ->
            [
              "<tr>",
              Enum.map(
                row,
                &[
                  "<td style=\"",
                  cell,
                  "\">",
                  HTML.escape(Lotus.Value.to_display_string(&1)),
                  "</td>"
                ]
              ),
              "</tr>"
            ]
          end),
          "</tbody></table>"
        ]
      end
    ]
  end

  defp html_dropped(nil, _max_bytes), do: []

  defp html_dropped(bytes, max_bytes),
    do: ["<p style=\"color:#b45309\">", HTML.escape(dropped_note(bytes, max_bytes)), "</p>"]

  defp text_body(content, dropped, max_bytes) do
    alert =
      case content.alert do
        nil -> []
        %{status: "firing", message: message} -> ["Alert: ", message, "\n\n"]
        %{message: message} -> ["Recovered: ", message, "\n\n"]
      end

    results =
      Enum.map(content.results, fn %{title: title, result: result} ->
        rows = Enum.take(result.rows, @preview_rows)
        total = result.num_rows || length(result.rows)

        lines =
          Enum.map(
            [
              result.columns
              | Enum.map(rows, fn row -> Enum.map(row, &Lotus.Value.to_display_string/1) end)
            ],
            &Enum.join(&1, " | ")
          )

        [title, " (", count(length(rows), total), ")\n", Enum.join(lines, "\n"), "\n\n"]
      end)

    dropped = if dropped, do: [dropped_note(dropped, max_bytes), "\n\n"], else: []

    IO.iodata_to_binary([content.title, "\n\n", alert, results, dropped, "Sent by Lotus"])
  end

  defp count(_shown, 0), do: "no rows"
  defp count(shown, total) when total > shown, do: "the first #{shown} of #{total} rows"
  defp count(_shown, 1), do: "1 row"
  defp count(_shown, total), do: "#{total} rows"

  defp dropped_note(bytes, max_bytes),
    do:
      "The attachment (#{megabytes(bytes)}) is larger than the #{megabytes(max_bytes)} an email takes here, so it was left out."

  defp megabytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe({_kind, reason}) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
