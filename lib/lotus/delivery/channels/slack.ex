defmodule Lotus.Delivery.Channels.Slack do
  @moduledoc """
  The `"slack"` channel: posts a run's results as a message in a Slack
  channel, through an [incoming webhook](https://api.slack.com/messaging/webhooks).

      %{
        channel: "slack",
        format: "csv",
        config: %{"webhook_url" => "https://hooks.slack.com/services/T000/B000/XXXX"}
      }

  The message has the schedule's name; for an alert, whether it fired or
  recovered and why; then, for each result (three at most), its first ten
  rows as a table and how many there are. Slack does not take files through
  an incoming webhook, so the delivery's format is not attached: the message
  is the preview.

  An incoming webhook is free: in Slack, create an app for the workspace,
  turn on its incoming webhooks and add one to a channel. Its URL is a
  secret: anyone who has it can post in the channel.

  A 2xx response is a delivery; anything else, or no answer within 15
  seconds, is a failure the run records. Like the webhook, it sends with
  [Req](https://hex.pm/packages/req), an optional dependency of Lotus, and
  takes `config :lotus, delivery: [slack: [req_options: [...]]]`.
  """

  @behaviour Lotus.Delivery.Channel

  alias Lotus.Delivery.HTTP

  @results 3
  @rows 10
  @cell 24
  # Slack refuses a section's text over 3000 characters.
  @section 2900

  @impl true
  def formats, do: :any

  @impl true
  def label, do: "Slack"

  @impl true
  def settings do
    [
      %{
        key: "webhook_url",
        label: "Incoming webhook URL",
        type: :secret,
        required: true,
        placeholder: "https://hooks.slack.com/services/…",
        help:
          "In Slack, create an app, turn on incoming webhooks and add one to the channel to post in."
      }
    ]
  end

  @impl true
  def available, do: HTTP.ensure_req("slack")

  @impl true
  def validate_config(config) do
    with :ok <- HTTP.ensure_req("slack") do
      case Map.get(config, "webhook_url") do
        url when is_binary(url) and url != "" -> validate_url(url)
        _ -> {:error, "a Slack delivery needs the incoming webhook's URL"}
      end
    end
  end

  # An incoming webhook's URL is on hooks.slack.com: another URL is a
  # mistake, often the URL of a channel or of another service.
  defp validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: "hooks.slack.com", path: "/" <> _}} ->
        :ok

      _ ->
        {:error, "the URL must be a Slack incoming webhook's, https://hooks.slack.com/services/…"}
    end
  end

  @impl true
  def deliver(content, _attachments, config) do
    with :ok <- validate_config(config) do
      options = Keyword.get(host_settings(), :req_options, [])

      case HTTP.post_json(config["webhook_url"], message(content), options) do
        {:ok, status, _body} when status in 200..299 -> :ok
        {:ok, status, body} -> {:error, "Slack answered #{status}: #{body}"}
        {:error, message} -> {:error, "Slack could not be reached: #{message}"}
      end
    end
  end

  defp host_settings, do: Keyword.get(Lotus.Config.delivery(), :slack, [])

  @doc false
  # The message, in Slack's Block Kit: its `text` is what notifications and
  # clients without blocks show.
  def message(content) do
    results = Enum.take(content.results, @results)
    more = length(content.results) - length(results)

    blocks =
      [header(content.title)] ++
        alert(content.alert) ++
        Enum.flat_map(results, &result/1) ++
        more_results(more) ++
        [footer(content)]

    %{"text" => text(content), "blocks" => blocks}
  end

  defp text(%{alert: %{status: "firing", message: message}, title: title}),
    do: "#{title}: #{message}"

  defp text(%{alert: %{message: message}, title: title}), do: "#{title} recovered: #{message}"
  defp text(%{title: title}), do: title

  defp header(title),
    do: %{
      "type" => "header",
      "text" => %{"type" => "plain_text", "text" => String.slice(title, 0, 150)}
    }

  defp alert(nil), do: []

  defp alert(%{status: status, message: message}) do
    mark =
      if status == "firing",
        do: ":rotating_light: *Alert*",
        else: ":white_check_mark: *Recovered*"

    [section("#{mark}: #{escape(message)}")]
  end

  defp result(%{title: title, result: result}) do
    rows = Enum.take(result.rows, @rows)
    total = result.num_rows || length(result.rows)

    count =
      cond do
        total == 0 -> "no rows"
        total > length(rows) -> "the first #{length(rows)} of #{total} rows"
        total == 1 -> "1 row"
        true -> "#{total} rows"
      end

    table = if rows == [], do: "", else: "\n```\n" <> table(result.columns, rows) <> "\n```"

    [section(fit("*#{escape(title)}* · #{count}" <> table))]
  end

  defp more_results(0), do: []

  defp more_results(n),
    do: [context("and #{n} more #{if n == 1, do: "result", else: "results"} in Lotus")]

  defp footer(content) do
    at = Calendar.strftime(content.run.scheduled_for, "%Y-%m-%d %H:%M UTC")
    context("Sent by Lotus · #{escape(content.schedule.name)} · #{at}")
  end

  # The cells padded to their column's width, each cut to @cell characters.
  defp table(columns, rows) do
    lines = [columns | Enum.map(rows, fn row -> Enum.map(row, &cell/1) end)]
    lines = Enum.map(lines, fn line -> Enum.map(line, &cut/1) end)

    widths =
      lines
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) end)

    lines
    |> Enum.map_join("\n", fn line ->
      line
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {value, width} -> String.pad_trailing(value, width) end)
      |> String.trim_trailing()
    end)
    |> escape()
  end

  defp cell(value), do: value |> Lotus.Value.to_display_string() |> String.replace(~r/\s+/, " ")

  defp cut(value) do
    value = to_string(value)
    if String.length(value) > @cell, do: String.slice(value, 0, @cell - 1) <> "…", else: value
  end

  # A section's text cut to what Slack takes, closing its code block.
  defp fit(text) do
    if String.length(text) <= @section do
      text
    else
      cut = String.slice(text, 0, @section)
      if String.contains?(cut, "```"), do: cut <> "\n…\n```", else: cut <> "…"
    end
  end

  defp section(text), do: %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}

  defp context(text),
    do: %{"type" => "context", "elements" => [%{"type" => "mrkdwn", "text" => text}]}

  # Slack reads &, < and > as markup.
  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
