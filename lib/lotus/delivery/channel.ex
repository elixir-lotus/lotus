defmodule Lotus.Delivery.Channel do
  @moduledoc """
  Sends a run's attachments somewhere.

  Lotus ships `"webhook"` (`Lotus.Delivery.Channels.Webhook`). Your app or
  Lotus Pro adds its own by name, an email channel for example:

      config :lotus, delivery: [channels: %{"email" => MyApp.EmailChannel}]

  A schedule's deliveries name a channel, a format and the channel's
  settings. The settings are data people enter: a channel validates them
  (`validate_config/1`) and never takes a module, a function or a path from
  them.

  ## What an editor shows

  Three optional callbacks let a dashboard (Lotus Web) draw a channel
  without knowing it: `label/0`, the name people see; `settings/0`, the
  fields a delivery's settings take; and `available/0`, whether the channel
  can send at all in this app (a dependency it needs, a setting of the
  host). `Lotus.Delivery.channel_specs/0` gathers them. A channel without
  `settings/0` is shown its settings as JSON.
  """

  @typedoc """
  A field of a delivery's settings, as an editor draws it:

    * `:key` - the key in the delivery's `config`;
    * `:label` - its name;
    * `:type` - `:text`, `:url`, `:secret` (a token or a password: shown
      masked), `:email_list` (a list of addresses), `:textarea` or `:select`;
    * `:required` - whether a delivery must have it (`false` by default);
    * `:placeholder`, `:help` - an example, and a sentence under the field;
    * `:options` - the `{label, value}` choices of a `:select`.

  The value of an `:email_list` is a list of strings; any other's a string.
  """
  @type setting :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:type) => :text | :url | :secret | :email_list | :textarea | :select,
          optional(:required) => boolean(),
          optional(:placeholder) => String.t(),
          optional(:help) => String.t(),
          optional(:options) => [{String.t(), String.t()}]
        }

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

  @doc "The channel's name for people: `\"Webhook\"`. Its registered name otherwise."
  @callback label() :: String.t()

  @doc "The fields of a delivery's settings, for an editor to draw."
  @callback settings() :: [setting()]

  @doc """
  Whether the channel can send in this app: `{:error, message}` when a
  dependency or a setting of the host is missing, naming it. A channel that
  is not available is not offered, and a delivery to it is refused when the
  schedule is saved and fails with the message when it runs.
  """
  @callback available() :: :ok | {:error, String.t()}

  @optional_callbacks label: 0, settings: 0, available: 0
end
