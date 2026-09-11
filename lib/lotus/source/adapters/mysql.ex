defmodule Lotus.Source.Adapters.MySQL do
  @moduledoc """
  MySQL data source, built on `Lotus.Source.Adapters.Ecto`.

  Resolved automatically for any repo whose Ecto adapter is
  `Ecto.Adapters.MyXQL`, so hosts normally never name this module —
  they configure the repo and Lotus wraps it.

  Dialect behaviour comes from
  `Lotus.Source.Adapters.Ecto.Dialects.MySQL`: databases-as-schemas, `EXPLAIN FORMAT=JSON` query plans, and `max_execution_time` as the statement timeout.
  """

  use Lotus.Source.Adapters.Ecto,
    dialect: Lotus.Source.Adapters.Ecto.Dialects.MySQL
end
