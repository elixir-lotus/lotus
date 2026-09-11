defmodule Lotus.Preflight do
  @moduledoc """
  Statement preflight authorization for Lotus.

  Delegates to the adapter's `extract_accessed_resources/2` callback to
  discover which tables/relations a statement will access, then checks
  those relations against visibility rules before execution.

  This provides defense-in-depth by blocking queries that would access
  denied tables, even if they're accessed through views or complex subqueries.

  When an adapter returns `{:unrestricted, reason}` the statement is allowed
  through only if the host application has opted in via
  `config :lotus, :allow_unrestricted_resources`; otherwise preflight raises.
  """

  alias Lotus.Config
  alias Lotus.Preflight.Relations
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Visibility

  @doc """
  Authorizes a statement by checking all relations it would access.

  Delegates resource extraction to the adapter, then validates each
  relation against the visibility rules.

  `scope` is the opaque caller-supplied value handed to the visibility
  resolver, the same one `Lotus.list_tables/2` and friends accept. Pass it
  and a per-scope deny blocks execution; omit it and only the unscoped
  rules apply. Without it a resolver that hides a table from one tenant
  would hide it in the explorer while the query still returned its rows.
  """
  @spec authorize(Adapter.t(), Statement.t(), String.t() | nil, term()) ::
          :ok | {:error, String.t()}
  def authorize(%Adapter{} = adapter, %Statement{} = statement, search_path \\ nil, scope \\ nil) do
    statement =
      if search_path,
        do: %{statement | meta: Map.put(statement.meta, :search_path, search_path)},
        else: statement

    case Adapter.extract_accessed_resources(adapter, statement) do
      {:ok, relations} ->
        rels = MapSet.to_list(relations)
        check_relations_visibility(rels, adapter.name, scope)

      {:error, e} ->
        {:error, normalize_preflight_error(e, adapter)}

      {:unrestricted, reason} ->
        handle_unrestricted(adapter, reason)
    end
  end

  defp handle_unrestricted(%Adapter{name: name}, reason) do
    if Config.allow_unrestricted_resources?(name) do
      :ok
    else
      {:error,
       "Preflight blocked: source #{inspect(name)} cannot enforce visibility at the " <>
         "adapter layer (#{reason}). Set `config :lotus, :allow_unrestricted_resources, true` " <>
         "or opt in per-source via `allow_unrestricted_resources: true` in the source's " <>
         "data_sources entry."}
    end
  end

  defp check_relations_visibility(rels, source_name, scope) do
    {allowed, blocked} =
      Enum.split_with(rels, &Visibility.allowed_relation?(source_name, &1, scope))

    if blocked == [] do
      Relations.put(allowed)
      :ok
    else
      {:error, "Query touches blocked table(s): #{format_relations(blocked)}"}
    end
  end

  defp format_relations(relations) do
    relations
    |> Enum.map(fn
      {nil, table} -> table
      {schema, table} -> "#{schema}.#{table}"
    end)
  end

  defp normalize_preflight_error(e, _adapter) when is_binary(e) do
    strip_explain_query_tail(e)
  end

  defp normalize_preflight_error(e, adapter) do
    e
    |> then(&Adapter.format_error(adapter, &1))
    |> strip_explain_query_tail()
  end

  defp strip_explain_query_tail(msg) do
    Regex.replace(~r/\n?query:\s*EXPLAIN[\s\S]*\z/i, msg, "")
    |> String.trim_trailing()
  end
end
