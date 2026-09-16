defmodule Lotus.Visibility.Resolvers.Static do
  @moduledoc """
  Default visibility resolver that reads from static application configuration.

  This resolver wraps the existing static config lookups behind the Visibility
  Resolver behaviour. It provides backward-compatible access to visibility rules
  configured via `Lotus.Config`.

  ## Configuration

  To use this resolver (the default), configure visibility rules in your application:

      config :lotus,
        schema_visibility: %{
          postgres: [
            allow: ["public", ~r/^tenant_/],
            deny: ["legacy"]
          ]
        },
        table_visibility: %{
          default: [
            deny: ["user_passwords", "api_keys"]
          ],
          postgres: [
            allow: [
              {"public", ~r/^dim_/},
              {"analytics", ~r/.*/}
            ]
          ]
        },
        column_visibility: %{
          default: [],
          postgres: []
        }

  When no source-specific rules are configured, the resolver falls back to
  `:default` rules, providing a sensible baseline for all sources.

  `matcher_for/2` returns the rules compiled once by `Lotus.Config` when the
  configuration was validated, merged with the built-in denies of the
  source's adapter. `Lotus.Config.reload!/0` rebuilds the compiled rules.
  """

  @behaviour Lotus.Visibility.Resolver

  alias Lotus.Visibility

  @impl true
  def schema_rules_for(source_name, _scope) do
    Lotus.Config.schema_rules_for_source_name(source_name)
  end

  @impl true
  def table_rules_for(source_name, _scope) do
    Lotus.Config.rules_for_source_name(source_name)
  end

  @impl true
  def column_rules_for(source_name, _scope) do
    Lotus.Config.column_rules_for_source_name(source_name)
  end

  @impl true
  def matcher_for(source_name, _scope) do
    source_name
    |> Lotus.Config.visibility_for_source_name()
    |> Visibility.compile(adapter: Visibility.source_adapter(source_name))
  end
end
