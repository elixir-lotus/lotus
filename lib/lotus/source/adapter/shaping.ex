defmodule Lotus.Source.Adapter.Shaping do
  @moduledoc """
  Capability behaviour for shaping the result set of a statement: filters,
  sorts, pagination, a row limit, the filter operators it supports and the
  identifier quoting those rewrites use.

  An adapter without it runs statements as written: filters, sorts,
  pagination and limits are no-ops.

  Declare it next to the core behaviour and implement every callback:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Shaping

  `Lotus.Source.Adapter` dispatches to these callbacks only when the module
  declares this behaviour. Exporting them without the declaration is not
  enough.
  """

  alias Lotus.Query.Statement

  @doc "Apply filters to the statement, returning a new statement with the filters baked in."
  @callback apply_filters(state :: term(), statement :: Statement.t(), filters :: list()) ::
              Statement.t()

  @doc "Apply sorts to the statement, returning a new statement with the sort order baked in."
  @callback apply_sorts(state :: term(), statement :: Statement.t(), sorts :: list()) ::
              Statement.t()

  @doc """
  Rewrite a statement to return a single page of rows, and optionally record
  a count query for the full result set.

  Pipeline position: fires **after** `apply_filters/3` and `apply_sorts/3`,
  so the input statement already has any filters and sorts applied.

  ## Opts

    * `:limit` (required) — page size
    * `:offset` — page offset (default: `0`)
    * `:count` — `:none` (default) or `:exact`. When `:exact`, the adapter
      picks one of two strategies to surface the pre-pagination total:

      **Strategy A — inline count.** The adapter arranges for its main
      query to return the total as a side-effect (e.g. Elasticsearch's
      `track_total_hits: true`, MongoDB's `$facet`). `execute_query/4`
      returns the count via the optional `:total_count` key in its result
      map. The adapter does *not* set `:count_spec` in `statement.meta`.

      **Strategy B — separate count query.** The adapter places a
      `count_spec` in `statement.meta[:count_spec]`; Lotus core runs it
      through the same adapter after the main query. Standard for SQL
      adapters (a `SELECT count(*) FROM ...` around the filtered query).

      Adapters pick one — not both. If both are present, Strategy A wins
      (the inline count from the main query is authoritative; the
      count_spec is not run).
    * `:search_path` — forwarded by callers that care about schema isolation

  ## Return

  A paginated `%Statement{}`. When counting is requested, the returned
  statement's `:meta` map holds `:count_spec` (a `count_spec()` value).
  Lotus core assembles any surrounding metadata (original adapter struct,
  search_path, etc.) from its own scope.

  Without this capability: statement unchanged, no pagination.
  """
  @callback apply_pagination(
              state :: term(),
              statement :: Statement.t(),
              pagination_opts :: keyword()
            ) ::
              Statement.t()

  @doc """
  Cap a statement at a source-specific row limit.

  Takes a `%Statement{}` and returns a `%Statement{}` whose body carries a
  single-page limit — a `LIMIT` / `TOP` / `FETCH FIRST` clause for SQL
  dialects, a `size` key for a JSON DSL, whatever the language calls it.
  Used by the UI's "preview this query" affordance to cap returned rows
  without touching the underlying query. `statement.params` is carried
  through untouched unless the adapter binds the limit itself.

  Without this capability: the statement unchanged. An adapter whose
  language has no notion of a row cap returns the statement unchanged —
  Lotus core treats the limit as best-effort and does not depend on it
  for correctness.
  """
  @callback limit_query(state :: term(), statement :: Statement.t(), limit :: pos_integer()) ::
              Statement.t()

  @doc """
  Return the `Lotus.Query.Filter` operators this adapter's `apply_filters/3`
  can handle.

  Core validates filter operators against this list before dispatching.
  Unsupported operators raise `Lotus.UnsupportedOperatorError` rather than
  silently degrading. lotus_web reads this through
  `Lotus.Source.supported_filter_operators/1` to gate the filter operator
  dropdown per source.

  Without this capability: the operators in `Lotus.Query.Filter.operators/0`
  but `Lotus.Query.Filter.text_operators/0` (`:contains`, `:starts_with`,
  `:ends_with`), which came later: an adapter declares them when its
  `apply_filters/3` matches text as written and without regard to case.
  An adapter declares the operators it actually supports.
  """
  @callback supported_filter_operators(state :: term()) :: [atom()]

  @doc "Quote a SQL identifier (column, table, schema name) using source-specific syntax."
  @callback quote_identifier(state :: term(), String.t()) :: String.t()
end
