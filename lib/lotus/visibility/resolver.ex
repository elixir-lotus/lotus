defmodule Lotus.Visibility.Resolver do
  @moduledoc """
  Behaviour for resolving visibility rules for a given data source.

  This is a **supported extension point**. The default implementation
  (`Lotus.Visibility.Resolvers.Static`) reads from static application
  configuration, which is all most applications need. Alternative
  implementations can load rules from registries, databases, feature
  flags, or per-tenant configuration — for example to change rules
  without restarting the application, or to scope rules to the current
  user or tenant.

  Configure a custom resolver via the `:visibility_resolver` config key:

      config :lotus,
        visibility_resolver: MyApp.VisibilityResolver

  ## Scope

  Every callback receives an opaque `scope` term as the second argument.
  Callers pass scope via the `:scope` option on discovery functions
  (e.g. `Lotus.list_tables("postgres", scope: %{role: :admin})`). When
  the caller does not pass a scope, it is `nil`.

  Scope is also hashed into the discovery cache key, so different scopes
  produce independent cached entries. Keep scope low-cardinality (per-role,
  per-tenant) for good cache hit rates.

  The default `Static` resolver ignores scope — it returns the same
  config-based rules regardless.

  The rule formats returned by each callback are the same as those
  consumed by the static resolver — see the [Visibility guide](visibility.html)
  for the full syntax, and the [Custom Resolvers guide](custom-resolvers.html)
  for contracts, minimal examples, and testing guidance.
  """

  @callback schema_rules_for(source_name :: String.t(), scope :: term()) :: keyword()
  @callback table_rules_for(source_name :: String.t(), scope :: term()) :: keyword()
  @callback column_rules_for(source_name :: String.t(), scope :: term()) :: list()

  @doc """
  Return the compiled matcher for a source.

  Optional. Without it, core compiles the three rule callbacks with
  `Lotus.Visibility.compile/2` on every result and every discovery call. A
  resolver that keeps rules in a store implements this to compile once when
  a rule set is written and hand back the compiled value. The matcher must
  include the built-in denies of the source's adapter: pass the adapter to
  `Lotus.Visibility.compile/2` as `:adapter`.
  """
  @callback matcher_for(source_name :: String.t(), scope :: term()) ::
              Lotus.Visibility.Matcher.t()

  @optional_callbacks matcher_for: 2
end
