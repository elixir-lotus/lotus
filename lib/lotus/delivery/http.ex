defmodule Lotus.Delivery.HTTP do
  @moduledoc false

  # POSTs JSON for the channels that send over HTTP (the webhook, Slack),
  # with Req, an optional dependency of Lotus: called through a variable, so
  # Lotus compiles without it.

  @timeout 15_000

  # The module an app without Req does not have; a setting only so that the
  # tests can stand for such an app.
  defp req, do: Application.get_env(:lotus, :__req_dependency__, Req)

  @doc "`:ok`, or the message for an app without Req, naming the channel."
  def ensure_req(channel) do
    if Code.ensure_loaded?(req()),
      do: :ok,
      else: {:error, ~s(the #{channel} channel needs Req: add {:req, "~> 0.5"} to your deps)}
  end

  @doc """
  POSTs `json` to `url`, waiting 15 seconds at most and without retrying:
  `{:ok, status, body}` for any answer, `{:error, message}` when there is
  none. `options` are Req's (headers, and the host's `req_options`).
  """
  def post_json(url, json, options) do
    options =
      Keyword.merge(
        [
          json: json,
          receive_timeout: @timeout,
          connect_options: [timeout: @timeout],
          retry: false
        ],
        options
      )

    case req().post(url, options) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body_text(body)}
      {:error, exception} -> {:error, error_message(exception)}
    end
  end

  # The HTTP client's message for a header it refused quotes the header's
  # value, which may be a credential: name the header only.
  defp error_message(%{reason: {:invalid_header_value, name, _value}}),
    do: "invalid value for header #{inspect(name)}"

  defp error_message(exception), do: Exception.message(exception)

  defp body_text(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp body_text(body), do: body |> inspect() |> String.slice(0, 200)
end
