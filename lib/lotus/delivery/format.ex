defmodule Lotus.Delivery.Format do
  @moduledoc """
  Renders the results of a run (`Lotus.Delivery.Content`) into attachments a
  channel sends.

  Lotus ships `"csv"` (`Lotus.Delivery.Formats.CSV`), `"json"`
  (`Lotus.Delivery.Formats.JSON`) and `"html"` (`Lotus.Delivery.Formats.HTML`).
  Your app or Lotus Pro adds its own by name:

      config :lotus, delivery: [formats: %{"xlsx" => MyApp.XlsxFormat}]
  """

  @typedoc "A file a channel sends: its name, its media type and its content."
  @type attachment :: %{filename: String.t(), content_type: String.t(), body: iodata()}

  @doc """
  Renders `content`. Returns one attachment, or one per result for a format
  that keeps results apart (CSV).
  """
  @callback render(content :: Lotus.Delivery.Content.t()) ::
              {:ok, [attachment(), ...]} | {:error, term()}
end
