defmodule Lotus.Source.Adapter.Preflight do
  @moduledoc """
  Capability behaviour for checking a statement before it runs: the safety
  check, the relations it reads, whether it needs the visibility preflight,
  dry-run validation, the execution plan and the statement the AI
  optimizer analyzes.

  An adapter without it runs every statement through the visibility
  preflight as `{:unrestricted, reason}`, so core consults the host's
  `:allow_unrestricted_resources` opt-in before letting it through.

  Declare it next to the core behaviour and implement every callback:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Preflight

  `Lotus.Source.Adapter` dispatches to these callbacks only when the module
  declares this behaviour. Exporting them without the declaration is not
  enough.
  """

  alias Lotus.Query.Statement

  @doc """
  Extract the set of tables/relations a statement will access.

  Used by `Lotus.Preflight` to check visibility rules before execution.
  Return `{:ok, MapSet}` with `{schema, table}` tuples, `{:error, reason}`,
  or `{:unrestricted, reason}` when visibility cannot be enforced at this
  layer (the adapter signals Lotus to consult the host-app opt-in gate
  before allowing the statement through).

  Without this capability: `{:unrestricted, "adapter ... does not declare Lotus.Source.Adapter.Preflight"}`.
  """
  @callback extract_accessed_resources(state :: term(), statement :: Statement.t()) ::
              {:ok, MapSet.t({String.t() | nil, String.t()})}
              | {:error, term()}
              | {:unrestricted, String.t()}

  @doc """
  Whether a statement needs the visibility preflight check before execution.

  Implementors return `false` for read-only introspection statements that do
  not access visible relations (e.g. SQL `EXPLAIN`, `SHOW`, `PRAGMA`) and
  `true` for everything else. Lotus core runs preflight when this callback
  returns `true` and skips it when `false`.

  Without this capability: `true` (always preflight — safer).
  """
  @callback needs_preflight?(state :: term(), statement :: Statement.t()) :: boolean()

  @doc """
  Validate that a statement is safe to execute.

  Called before execution to enforce single-statement and deny-list rules.
  Return `:ok` to allow or `{:error, reason}` to block.

  ## Options

    * `:read_only` — when `true`, block write operations

  Without this capability: `:ok` (allow all statements).
  """
  @callback sanitize_query(state :: term(), statement :: Statement.t(), opts :: keyword()) ::
              :ok | {:error, String.t()}

  @doc """
  Return an execution plan for a query.

  For SQL-prepared adapters, this is typically the output of the dialect's
  EXPLAIN variant (e.g. `EXPLAIN` on Postgres, `EXPLAIN QUERY PLAN` on
  SQLite, `EXPLAIN FORMAT=JSON` on MySQL) — a human-readable or structured
  string describing how the server will execute the query.

  Non-SQL adapters whose engines don't expose a plan (or don't expose one
  cheaply) may legitimately return `{:ok, nil}` or `{:error, :unsupported}`;
  Lotus callers treat both as "no plan available" without surfacing an
  error to the user.

  The statement carries its own bound values in `statement.params`; there is
  no separate params argument.
  """
  @callback query_plan(state :: term(), statement :: Statement.t(), opts :: keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc """
  Validate that a statement can be parsed and prepared by the data source
  without executing it.

  SQL-prepared adapters typically implement this via `EXPLAIN` (the server
  parses + type-checks the query without running it). Non-SQL engines
  might use a `_validate` endpoint (Elasticsearch) or return `:ok`
  unconditionally as a trust-on-execute fallback.

  Called by lotus_web's "validate before run" feature and AI actions that
  want to sanity-check a draft before surfacing it to the user. Callers
  are responsible for neutralizing any unbound `{{var}}` placeholders
  before calling this — adapters see the statement as-is.

  Without this capability: `:ok` — trust-on-execute; errors surface
  at run time.
  """
  @callback validate_statement(
              state :: term(),
              statement :: Statement.t(),
              opts :: keyword()
            ) ::
              :ok | {:error, term()}

  @doc """
  Return a statement safe to pass to `query_plan/3` for optimization
  analysis.

  Callers (`Lotus.AI.QueryOptimizer`) run this first so the adapter can
  resolve any `[[ ... ]]` optional clauses and replace `{{var}}`
  placeholders with language-appropriate null-ish literals (`NULL` for
  SQL, `null` for JSON DSLs). The returned statement's `:body` must be
  syntactically valid in the adapter's language without bound params
  so the engine's EXPLAIN / profile endpoint can parse it.

  Without this capability: `{:error, :unsupported}` — the caller
  skips optimization analysis for this adapter.
  """
  @callback prepare_for_analysis(state :: term(), statement :: Statement.t()) ::
              {:ok, Statement.t()} | {:error, term()}
end
