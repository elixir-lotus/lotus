defmodule Lotus.Source.Adapter.Binding do
  @moduledoc """
  Capability behaviour for turning a statement with `{{var}}` placeholders
  into one the source can run: the rewrites before and after binding, the
  binding of scalar and list values, and the mapping of the source's column
  types to Lotus types.

  An adapter without it accepts no variables: binding a `{{var}}` returns
  `{:error, :unsupported}`.

  Declare it next to the core behaviour and implement every callback:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Binding

  `Lotus.Source.Adapter` dispatches to these callbacks only when the module
  declares this behaviour. Exporting them without the declaration is not
  enough.
  """

  alias Lotus.Query.Statement

  @doc """
  Rewrite the statement before variables are extracted and bound.

  Pipeline position: fires inside `Lotus.Storage.Query.compile/2`
  **before** `{{var}}` placeholders are extracted from `statement.body` and
  before any value is bound. The statement's `:params` is `[]` at this point.

  Use for language-specific syntax normalization of the stored template
  (e.g., wildcard rewriting, quoted-variable stripping). Works for any
  query language: SQL text, JSON DSL, Cypher, etc.

  For rewrites that need access to the resolved param values (post-binding),
  implement `transform_bound_query/3` instead.

  Without this capability: statement unchanged.
  """
  @callback transform_statement(state :: term(), statement :: Statement.t()) :: Statement.t()

  @doc """
  Substitute a `{{var_name}}` placeholder in the statement with the given
  value, returning a new statement.

  Adapters own their substitution strategy because it depends on the query
  language:

    * SQL (prepared-statement) drivers add a placeholder (`$1`, `?`, ...) to
      `statement.body`, append the value to `statement.params`, and leave
      binding to the driver.
    * JSON / DSL adapters (Elasticsearch, Mongo) inline the value as a
      properly-escaped literal inside `statement.body`.

  `value` has already been type-cast by Lotus core. `type` is the resolved
  Lotus internal type atom (e.g. `:integer`, `:uuid`) — adapters that care
  about type-specific placeholders use it; others may ignore it.

  Return `{:error, :unsupported}` when the adapter has no `{{var}}` mental
  model (e.g. an adapter whose statement is a fully pre-built term and does
  not accept user variables at all).

  **Security note.** Adapters that inline values are the only defense
  against injection at this layer. Never interpolate raw strings —
  delegate to `Lotus.JSON` or an equivalent escaper for the target
  language.

  Without this capability: `{:error, :unsupported}`.
  """
  @callback substitute_variable(
              state :: term(),
              statement :: Statement.t(),
              var_name :: String.t(),
              value :: term(),
              type :: atom() | nil
            ) ::
              {:ok, Statement.t()} | {:error, term()}

  @doc """
  Substitute a `{{var_name}}` list-variable placeholder with the given list
  of values, returning a new statement.

  Adapters choose the natural shape for their query language: SQL expands
  into a placeholder group (`$1, $2, $3`); JSON DSLs emit a JSON array.
  Callers must not rely on the substituted text form beyond "the variable
  has been expanded into the statement's native list representation".

  `values` is a non-empty list of already-cast values. `type` is the
  resolved Lotus internal type atom shared by all list elements.

  Without this capability: `{:error, :unsupported}`.
  """
  @callback substitute_list_variable(
              state :: term(),
              statement :: Statement.t(),
              var_name :: String.t(),
              values :: [term()],
              type :: atom() | nil
            ) ::
              {:ok, Statement.t()} | {:error, term()}

  @doc """
  Rewrite the statement after variable substitution.

  Pipeline position: fires inside the execution pipeline **after**
  `{{var}}` placeholders have been resolved into `statement.params`, and
  **before** `apply_filters`, `apply_sorts`, and `apply_pagination` mutate
  the statement.

  Use when you need access to the bound parameter values — for example, to
  inline values into `statement.body` for a transport that can't carry
  prepared-statement parameters, or to apply a transformation that depends on
  the bound values.

  The statement payload is whatever the adapter understands (SQL text, JSON
  DSL, AST, etc.); this callback is language-agnostic. For rewrites that only
  need the raw statement text (before variables are bound), implement
  `transform_statement/2` instead.

  Without this capability: statement unchanged.
  """
  @callback transform_bound_query(
              state :: term(),
              statement :: Statement.t(),
              opts :: keyword()
            ) ::
              Statement.t()

  @doc "Map a database column type string to a Lotus internal type atom."
  @callback db_type_to_lotus_type(state :: term(), db_type :: String.t()) :: atom()
end
