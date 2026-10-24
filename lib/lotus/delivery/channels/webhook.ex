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

  A 2xx response is a delivery; anything else, or no answer within 15
  seconds, is a failure the run records. `"headers"` are sent as given, for
  a token the receiver checks.

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
  def validate_config(config) do
    with {:ok, url} <- fetch_url(config),
         :ok <- validate_url(url) do
      validate_headers(Map.get(config, "headers", %{}))
    end
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

  defp allow_http? do
    Lotus.Config.delivery()
    |> Keyword.get(:webhook, [])
    |> Keyword.get(:allow_http, false)
  end

  @impl true
  def deliver(content, attachments, config) do
    with :ok <- validate_config(config) do
      body = Lotus.JSON.encode!(envelope(content, attachments))

      headers =
        config
        |> Map.get("headers", %{})
        |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      post(config["url"], headers, body)
    end
  end

  defp envelope(content, attachments) do
    %{
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
  end

  defp post(url, headers, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), headers, ~c"application/json", body}
    http_options = [timeout: @timeout, connect_timeout: @timeout, ssl: ssl_options()]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_version, status, _reason}, _headers, response}} ->
        {:error, "the webhook answered #{status}: #{String.slice(to_string(response), 0, 200)}"}

      {:error, reason} ->
        {:error, "the webhook could not be reached: #{inspect(reason)}"}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
