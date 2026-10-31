defmodule Lotus.Delivery.Redact do
  @moduledoc false

  # Delivery settings hold credentials (a webhook's authorization, a Slack
  # webhook URL), which telemetry hands to every handler. A schedule's
  # deliveries, wherever they sit in an event's metadata, keep only the
  # settings their channel declares and not as `:secret`; any other value
  # reads "[REDACTED]".

  alias Ecto.Changeset
  alias Lotus.Delivery
  alias Lotus.Storage.{Schedule, ScheduleDelivery, ScheduleRun}

  @redacted "[REDACTED]"

  @spec metadata(map()) :: map()
  def metadata(metadata) when is_map(metadata),
    do: Map.new(metadata, fn {k, v} -> {k, redact(v)} end)

  defp redact(%Schedule{deliveries: deliveries} = schedule) when is_list(deliveries),
    do: %{schedule | deliveries: Enum.map(deliveries, &redact/1)}

  defp redact(%ScheduleRun{schedule: %Schedule{} = schedule} = run),
    do: %{run | schedule: redact(schedule)}

  defp redact(%ScheduleDelivery{channel: channel, config: config} = delivery),
    do: %{delivery | config: config(channel, config)}

  defp redact(%Changeset{data: %ScheduleDelivery{channel: channel}} = changeset) do
    channel = Map.get(changeset.changes, :channel, channel)
    changes = Map.update(changeset.changes, :config, nil, &config(channel, &1))
    %{changeset | data: redact(changeset.data), changes: changes, params: nil}
  end

  defp redact(%Changeset{data: %Schedule{}} = changeset) do
    changes = Map.new(changeset.changes, fn {k, v} -> {k, redact(v)} end)
    %{changeset | data: redact(changeset.data), changes: changes, params: nil}
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  defp redact(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, redact(v)} end)

  defp redact(other), do: other

  defp config(channel, config) when is_map(config) do
    shown = shown_keys(channel)
    Map.new(config, fn {k, v} -> {k, if(to_string(k) in shown, do: v, else: @redacted)} end)
  end

  defp config(_channel, config), do: config

  defp shown_keys(channel) do
    with {:ok, module} <- Map.fetch(Delivery.channels(), channel),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :settings, 0) do
      for %{key: key, type: type} <- module.settings(), type != :secret, do: key
    else
      _ -> []
    end
  end
end
