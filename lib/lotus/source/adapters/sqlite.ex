defmodule Lotus.Source.Adapters.SQLite3 do
  @moduledoc """
  SQLite data source, built on `Lotus.Source.Adapters.Ecto`.

  Resolved automatically for any repo whose Ecto adapter is
  `Ecto.Adapters.SQLite3`, so hosts normally never name this module —
  they configure the repo and Lotus wraps it.

  Dialect behaviour comes from
  `Lotus.Source.Adapters.Ecto.Dialects.SQLite3`: a flat namespace (no schemas) and `EXPLAIN QUERY PLAN` query plans.

  It doesn't declare `Lotus.Source.Adapter.Streaming`: the SQLite driver
  doesn't name the columns of the rows it streams, and column policies
  apply by name. `Lotus.stream_query/3` runs the statement once and hands
  its rows over in chunks.
  """

  use Lotus.Source.Adapters.Ecto,
    dialect: Lotus.Source.Adapters.Ecto.Dialects.SQLite3,
    connection: [
      kind: "sqlite",
      label: "SQLite",
      fields: [
        %{
          key: :database,
          label: "File",
          type: :string,
          required: true,
          placeholder: "/var/data/app.db",
          hint: "The path of the database file on the server."
        }
      ]
    ]

  # Opening a file that is not there would make an empty database.
  @impl Lotus.Source.Adapter.Connection
  def from_settings(name, settings) do
    if File.regular?(settings[:database]),
      do: super(name, settings),
      else: {:error, %{database: "There is no database file at #{settings[:database]}."}}
  end
end
