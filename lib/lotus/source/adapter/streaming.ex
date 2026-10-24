defmodule Lotus.Source.Adapter.Streaming do
  @moduledoc """
  Capability behaviour for sources that read a statement's rows as they are
  consumed, rather than all at once. `Lotus.stream_query/3` and
  `Lotus.Export.stream/4` use it, so an export of a million rows holds one
  chunk at a time.

  The built-in PostgreSQL, MySQL and SQLite adapters declare it, with
  `Ecto.Adapters.SQL.stream/4`. A source without it still streams through the
  same API: Lotus runs the statement once and hands its rows over in chunks.

  Declare it next to the core behaviour:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Streaming

  `Lotus.Source.Adapter` dispatches to it only when the module declares this
  behaviour.
  """

  @doc """
  Return a lazy `Enumerable` of chunks of the statement's rows, each a map
  with `:columns` and `:rows`, as `c:Lotus.Source.Adapter.execute_query/4`
  returns them.

  Lotus calls it inside the statement's transaction
  (`c:Lotus.Source.Adapter.transaction/3`) and enumerates the stream before
  the transaction ends; the rows must be read only as it is enumerated.
  `opts` carries `:max_rows`, the most rows a chunk should hold, and the
  options of `execute_query/4`. Every chunk carries the columns, and an empty
  result yields one chunk with no rows. A source error before the stream
  exists is `{:error, reason}`; one while it is read raises.
  """
  @callback stream_query(
              state :: term(),
              body :: term(),
              params :: list() | map(),
              opts :: keyword()
            ) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
