defmodule Lotus.Delivery.Channel do
  @moduledoc """
  Sends a run's attachments somewhere.

  Lotus ships `"webhook"` (`Lotus.Delivery.Channels.Webhook`). A host or a
  package adds its own by name, an email channel for example:

      config :lotus, delivery: [channels: %{"email" => MyApp.EmailChannel}]

  A schedule's deliveries name a channel, a format and the channel's
  settings. The settings are data people enter: a channel validates them
  (`validate_config/1`) and never takes a module, a function or a path from
  them.
  """

  @doc "The formats the channel sends, by name, or `:any`."
  @callback formats() :: [String.t()] | :any

  @doc """
  Checks a delivery's settings when the schedule is saved. `{:error, message}`
  is shown on the delivery.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}

  @doc """
  Sends the attachments of `content`. Called once per delivery and run; a
  retried run calls it again only for the deliveries that failed.
  """
  @callback deliver(
              content :: Lotus.Delivery.Content.t(),
              attachments :: [Lotus.Delivery.Format.attachment(), ...],
              config :: map()
            ) :: :ok | {:error, term()}
end
