defmodule Lotus.Delivery do
  @moduledoc """
  Sends the results of a schedule's runs somewhere: the deliveries of a
  `Lotus.Storage.Schedule`.

  Each delivery names a channel (`Lotus.Delivery.Channel`), a format
  (`Lotus.Delivery.Format`) and the channel's settings:

      Lotus.Schedules.create_schedule(%{
        name: "Weekly revenue",
        dashboard_id: dashboard.id,
        cron: "0 8 * * MON",
        deliveries: [
          %{channel: "webhook", format: "csv", config: %{"url" => "https://hooks.example.com/lotus"}}
        ]
      })

  After a run succeeds, `Lotus.Scheduler.Worker` renders each delivery's
  format and hands the attachments to its channel. Each delivery's outcome
  is recorded on the run (`details["deliveries"]`, by delivery id); a run
  whose delivery failed is failed, and a retry of it (with Oban) delivers
  again only what failed.

  ## Channels and formats

  Built in: the `"webhook"`, `"slack"` and `"email"` channels, and the
  `"csv"`, `"json"` and `"html"` formats. Your app or Lotus Pro registers more by name; a name here wins
  over a built-in one:

      config :lotus,
        delivery: [
          channels: %{"email" => MyApp.EmailChannel},
          formats: %{"xlsx" => MyApp.XlsxFormat}
        ]

  A delivery stores names, never modules: its settings are data people enter.
  """

  require Logger

  alias Lotus.Delivery.{Channels, Content, Formats}
  alias Lotus.Telemetry

  @builtin_channels %{
    "webhook" => Channels.Webhook,
    "slack" => Channels.Slack,
    "email" => Channels.Email
  }

  @builtin_formats %{
    "csv" => Formats.CSV,
    "json" => Formats.JSON,
    "html" => Formats.HTML
  }

  @doc "The channels, by name: the built-in ones and those configured."
  @spec channels() :: %{String.t() => module()}
  def channels, do: Map.merge(@builtin_channels, configured(:channels))

  @doc "The formats, by name: the built-in ones and those configured."
  @spec formats() :: %{String.t() => module()}
  def formats, do: Map.merge(@builtin_formats, configured(:formats))

  defp configured(key), do: Lotus.Config.delivery() |> Keyword.get(key) || %{}

  @typedoc "A channel as an editor shows it; see `channel_specs/0`."
  @type channel_spec :: %{
          name: String.t(),
          label: String.t(),
          settings: [Lotus.Delivery.Channel.setting()] | nil,
          formats: [String.t()],
          available: :ok | {:error, String.t()}
        }

  @doc """
  Every channel as an editor shows it, sorted by label: its name, its label,
  the fields of its settings (`nil` for a channel that does not describe
  them), the formats it sends, and whether it can send in this app
  (`c:Lotus.Delivery.Channel.available/0`).
  """
  @spec channel_specs() :: [channel_spec()]
  def channel_specs do
    format_names = formats() |> Map.keys() |> Enum.sort()

    channels()
    |> Enum.map(fn {name, module} ->
      Code.ensure_loaded(module)

      %{
        name: name,
        label: optional(module, :label, name),
        settings: optional(module, :settings, nil),
        formats: channel_formats(module, format_names),
        available: optional(module, :available, :ok)
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.label))
  end

  defp optional(module, callback, default) do
    if function_exported?(module, callback, 0), do: apply(module, callback, []), else: default
  end

  defp channel_formats(module, format_names) do
    case module.formats() do
      :any -> format_names
      formats -> Enum.filter(format_names, &(&1 in formats))
    end
  end

  @doc """
  Checks a delivery: a known channel, a known format the channel sends, and
  settings the channel accepts. Returns the field and message of the first
  problem.
  """
  @spec validate(String.t() | nil, String.t() | nil, map()) ::
          :ok | {:error, :channel | :format | :config, String.t()}
  def validate(channel, format, config) do
    with {:ok, channel_module} <- fetch(channels(), channel, :channel),
         :ok <- available(channel_module),
         {:ok, _format_module} <- fetch(formats(), format, :format),
         :ok <- accepts(channel_module, channel, format) do
      case channel_module.validate_config(config || %{}) do
        :ok -> :ok
        {:error, message} -> {:error, :config, message}
      end
    end
  end

  defp fetch(registry, name, field) do
    case Map.fetch(registry, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, field, "is not a known #{field}: #{inspect(name)}"}
    end
  end

  defp available(module) do
    Code.ensure_loaded(module)

    case optional(module, :available, :ok) do
      :ok -> :ok
      {:error, message} -> {:error, :channel, message}
    end
  end

  defp accepts(module, channel, format) do
    case module.formats() do
      :any ->
        :ok

      formats ->
        if format in formats,
          do: :ok,
          else: {:error, :format, "#{channel} does not send #{format}"}
    end
  end

  @doc false
  # The alert of a content as JSON has it, for the formats and channels that
  # send JSON.
  def alert_json(%{status: status, value: value, message: message}),
    do: %{"status" => status, "value" => value, "message" => message}

  @doc """
  Sends a test to one delivery, as an editor's "Send a test" does: sample
  results (two rows), titled "Test: " and the `:title` option, to the
  channel with the format and settings given, now. `alert: true` sends it
  as an alert that fired, to see how one looks.

  It checks the delivery as `validate/3` does first, so a channel that is not
  available or settings it refuses are said before anything is sent. Returns
  `:ok`, or `{:error, message}` with the channel's reason (an answer that is
  not 2xx, a mailer that refuses), for people to read.
  """
  @spec send_test(String.t(), String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def send_test(channel, format, config, opts \\ []) do
    content = test_content(opts)

    with :ok <- test_validate(channel, format, config),
         {:ok, channel_module} <- fetch(channels(), channel, :channel),
         {:ok, format_module} <- fetch(formats(), format, :format),
         {:ok, attachments} <- format_module.render(content),
         :ok <- channel_module.deliver(content, attachments, config) do
      :ok
    else
      {:error, _field, message} -> {:error, message}
      {:error, reason} -> {:error, describe(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp test_validate(channel, format, config) do
    case validate(channel, format, config) do
      :ok -> :ok
      {:error, _field, message} -> {:error, message}
    end
  end

  defp test_content(opts) do
    title = "Test: " <> (Keyword.get(opts, :title) || "a Lotus report")

    alert =
      if Keyword.get(opts, :alert, false),
        do: %{status: "firing", value: 1_200, message: "total is above 1000 (a test)"}

    %Content{
      title: title,
      results: [
        %{
          title: "Sample results",
          result: Lotus.Result.new(["region", "total"], [["North", 1_200], ["South", 980]])
        }
      ],
      schedule: %Lotus.Storage.Schedule{name: title},
      run: %Lotus.Storage.ScheduleRun{scheduled_for: DateTime.utc_now()},
      alert: alert
    }
  end

  @doc """
  Sends `content` to each delivery that has not succeeded yet in `previous`
  (the outcomes of an earlier attempt of the same run, by delivery id).
  Returns every delivery's outcome, by id: `%{"status" => "delivered"}` or
  `%{"status" => "failed", "error" => message}`.

  Each delivery is bracketed by `[:lotus, :delivery, :start | :stop | :exception]`
  telemetry; see `Lotus.Telemetry`.
  """
  @spec deliver_all(Content.t(), [map()], map()) :: %{String.t() => map()}
  def deliver_all(%Content{} = content, deliveries, previous \\ %{}) do
    {outcomes, _rendered} =
      Enum.reduce(deliveries, {%{}, %{}}, fn delivery, {outcomes, rendered} ->
        id = delivery.id

        case previous[id] do
          %{"status" => "delivered"} = done ->
            {Map.put(outcomes, id, done), rendered}

          _not_yet ->
            {outcome, rendered} = deliver(content, delivery, rendered)
            {Map.put(outcomes, id, outcome), rendered}
        end
      end)

    outcomes
  end

  # Attachments are rendered once per format and run, however many
  # deliveries share the format.
  defp deliver(content, delivery, rendered) do
    metadata = %{
      schedule: content.schedule,
      run: content.run,
      delivery: %{id: delivery.id, channel: delivery.channel, format: delivery.format}
    }

    start_time = Telemetry.delivery_start(metadata)

    {result, rendered} =
      try do
        with {:ok, channel} <- fetch(channels(), delivery.channel, :channel),
             :ok <- available(channel),
             {:ok, format} <- fetch(formats(), delivery.format, :format),
             {:ok, attachments, rendered} <- render(format, delivery.format, content, rendered) do
          {channel.deliver(content, attachments, delivery.config || %{}), rendered}
        else
          {:error, _field, message} -> {{:error, message}, rendered}
          {:error, reason} -> {{:error, reason}, rendered}
        end
      rescue
        e -> {{:error, Exception.message(e)}, rendered}
      end

    case result do
      :ok ->
        Telemetry.delivery_stop(start_time, metadata)
        {%{"status" => "delivered"}, rendered}

      {:error, reason} ->
        message = describe(reason)
        Telemetry.delivery_exception(start_time, Map.put(metadata, :reason, message))
        Logger.warning("Lotus delivery #{delivery.id} (#{delivery.channel}) failed: #{message}")
        {%{"status" => "failed", "error" => message}, rendered}
    end
  end

  defp render(module, name, content, rendered) do
    case Map.fetch(rendered, name) do
      {:ok, attachments} ->
        {:ok, attachments, rendered}

      :error ->
        with {:ok, attachments} <- module.render(content),
             do: {:ok, attachments, Map.put(rendered, name, attachments)}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
