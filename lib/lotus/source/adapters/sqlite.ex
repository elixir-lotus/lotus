defmodule Lotus.Source.Adapters.SQLite3 do
  @moduledoc """
  SQLite data source, built on `Lotus.Source.Adapters.Ecto`.

  Resolved automatically for any repo whose Ecto adapter is
  `Ecto.Adapters.SQLite3`, so hosts normally never name this module —
  they configure the repo and Lotus wraps it.

  Dialect behaviour comes from
  `Lotus.Source.Adapters.Ecto.Dialects.SQLite3`: a flat namespace (no schemas) and `EXPLAIN QUERY PLAN` query plans.
  """

  use Lotus.Source.Adapters.Ecto,
    dialect: Lotus.Source.Adapters.Ecto.Dialects.SQLite3

  @behaviour Lotus.Source.Adapter.Streaming

  @impl Lotus.Source.Adapter.Streaming
  defdelegate stream_query(state, sql, params, opts),
    to: Lotus.Source.Adapters.Ecto,
    as: :do_stream_query
end
