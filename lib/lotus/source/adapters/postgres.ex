defmodule Lotus.Source.Adapters.Postgres do
  @moduledoc """
  PostgreSQL data source, built on `Lotus.Source.Adapters.Ecto`.

  Resolved automatically for any repo whose Ecto adapter is
  `Ecto.Adapters.Postgres`, so hosts normally never name this module —
  they configure the repo and Lotus wraps it.

  Dialect behaviour comes from
  `Lotus.Source.Adapters.Ecto.Dialects.Postgres`: schemas, `EXPLAIN (FORMAT JSON)` query plans, a session `search_path`, and `statement_timeout`.
  """

  use Lotus.Source.Adapters.Ecto,
    dialect: Lotus.Source.Adapters.Ecto.Dialects.Postgres
end
