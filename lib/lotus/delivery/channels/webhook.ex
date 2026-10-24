defmodule Lotus.Delivery.Channels.Webhook do
  @moduledoc """
  The `"webhook"` channel: POSTs a run's attachments as JSON to a URL.

      %{
        channel: "webhook",
        format: "csv",
        config: %{"url" => "https://hooks.example.com/lotus", "headers" => %{"authorization" => "Bearer ..."}}
      }

  The body:

      {"title": "Weekly revenue",
       "schedule": {"id": 7, "name": "Weekly revenue"},
       "run": {"id": 42, "scheduled_for": "2026-10-26T08:00:00.000000Z"},
       "attachments": [{"filename": "revenue.csv", "content_type": "text/csv", "content": "region,total\\n..."}]}

  An alert's has `"alert"` too, as the `"json"` format has it.

  A 2xx response is a delivery; anything else, or no answer within 15
  seconds, is a failure the run records. `"headers"` are sent as given, for
  a token the receiver checks; `"authorization"` is a shortcut for the
  `authorization` header, the one field an editor shows besides the URL
  (`settings/0`).

  ## Req

  The webhook sends with [Req](https://hex.pm/packages/req), an optional
  dependency of Lotus: add `{:req, "~> 0.5"}` to your deps to use it. An app
  that has the AI features has it already. Without it, a webhook delivery is
  refused when the schedule is saved. `config :lotus, delivery: [webhook:
  [req_options: [...]]]` passes options to every request, such as a proxy.

  ## Settings

  The URL is entered by people, so it must be `https`: the certificate is
  verified. `config :lotus, delivery: [webhook: [allow_http: true]]` allows
  plain `http`, for a receiver on a private network. Lotus does not restrict
  which hosts a URL names; a host that needs to keeps people who may edit
  schedules away from internal addresses, or refuses them in a
  `:before_content_change` plug.
  """

  @behaviour Lotus.Delivery.Channel

  @timeout 15_000

  @impl true
  def formats, do: :any

  @impl true
  def label, do: "Webhook"

  @impl true
  def settings do
    [
      %{
        key: "url",
        label: "URL",
        type: :url,
        required: true,
        placeholder: "https://",
        help: "Lotus POSTs JSON here, with the results attached. Any 2xx answer is a delivery."
      },
      %{
        key: "authorization",
        label: "Authorization header",
        type: :secret,
        placeholder: "Bearer …",
        help: "Sent as the authorization header, for a token the receiver checks."
      }
    ]
  end

  @impl true
  def available, do: ensure_req()

  @impl true
  def validate_config(config) do
    with :ok <- ensure_req(),
         {:ok, url} <- fetch_url(config),
         :ok <- validate_url(url),
         :ok <- validate_authorization(Map.get(config, "authorization")) do
      validate_headers(Map.get(config, "headers", %{}))
    end
  end

  defp validate_authorization(nil), do: :ok
  defp validate_authorization(value) when is_binary(value), do: :ok
  defp validate_authorization(_value), do: {:error, "the authorization must be a string"}

  # The module an app without Req does not have; a setting only so that the
  # tests can stand for such an app.
  defp req, do: Application.get_env(:lotus, :__req_dependency__, Req)

  defp ensure_req do
    if Code.ensure_loaded?(req()),
      do: :ok,
      else: {:error, ~s(the webhook channel needs Req: add {:req, "~> 0.5"} to your deps)}
  end

  defp fetch_url(config) do
    case Map.get(config, "url") do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, "a webhook needs a url"}
    end
  end

  defp validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        :ok

      {:ok, %URI{scheme: "http", host: host}} when is_binary(host) and host != "" ->
        if allow_http?(), do: :ok, else: {:error, "the url must be https"}

      _ ->
        {:error, "the url must be an https URL"}
    end
  end

  defp validate_headers(headers) when is_map(headers) do
    if Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: :ok,
      else: {:error, "headers must map names to strings"}
  end

  defp validate_headers(_headers), do: {:error, "headers must map names to strings"}

  defp allow_http?, do: Keyword.get(host_settings(), :allow_http, false)

  # The host's settings of the channel, `config :lotus, delivery: [webhook: ...]`.
  defp host_settings, do: Keyword.get(Lotus.Config.delivery(), :webhook, [])

  @impl true
  def deliver(content, attachments, config) do
    with :ok <- validate_config(config) do
      options =
        [
          json: envelope(content, attachments),
          headers: headers(config),
          receive_timeout: @timeout,
          connect_options: [timeout: @timeout],
          retry: false
        ]
        |> Keyword.merge(Keyword.get(host_settings(), :req_options, []))

      post(config["url"], options)
    end
  end

  defp headers(config) do
    headers = Map.get(config, "headers", %{})

    case config["authorization"] do
      value when is_binary(value) and value != "" -> Map.put(headers, "authorization", value)
      _none -> headers
    end
  end

  defp envelope(content, attachments) do
    envelope = %{
      "title" => content.title,
      "schedule" => %{"id" => content.schedule.id, "name" => content.schedule.name},
      "run" => %{"id" => content.run.id, "scheduled_for" => content.run.scheduled_for},
      "attachments" =>
        Enum.map(attachments, fn attachment ->
          %{
            "filename" => attachment.filename,
            "content_type" => attachment.content_type,
            "content" => IO.iodata_to_binary(attachment.body)
          }
        end)
    }

    case content.alert do
      nil -> envelope
      alert -> Map.put(envelope, "alert", Lotus.Delivery.alert_json(alert))
    end
  end

  # Req is optional: called through a variable, so Lotus compiles without it.
  defp post(url, options) do
    case req().post(url, options) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "the webhook answered #{status}: #{String.slice(to_string_body(body), 0, 200)}"}

      {:error, exception} ->
        {:error, "the webhook could not be reached: #{Exception.message(exception)}"}
    end
  end

  defp to_string_body(body) when is_binary(body), do: body
  defp to_string_body(body), do: inspect(body)
end
