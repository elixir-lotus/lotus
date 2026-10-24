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

  Built in: the `"webhook"` channel, and the `"csv"`, `"json"` and `"html"`
  formats. A host or a package registers more by name; a name here wins over
  a built-in one:

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

  @builtin_channels %{"webhook" => Channels.Webhook}

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

  @doc """
  Checks a delivery: a known channel, a known format the channel sends, and
  settings the channel accepts. Returns the field and message of the first
  problem.
  """
  @spec validate(String.t() | nil, String.t() | nil, map()) ::
          :ok | {:error, :channel | :format | :config, String.t()}
  def validate(channel, format, config) do
    with {:ok, channel_module} <- fetch(channels(), channel, :channel),
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
