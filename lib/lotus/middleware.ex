defmodule Lotus.Middleware do
  @moduledoc """
  Generic middleware pipeline for query execution and schema discovery hooks.

  Each middleware module implements `init/1` and `call/2`, following
  the standard Plug pattern:

      defmodule MyApp.AuditPlug do
        def init(opts), do: opts

        def call(payload, opts) do
          {:cont, payload}   # continue to next middleware
          # or
          {:halt, "reason"}  # stop pipeline, Lotus returns {:error, reason}
        end
      end

  ## Pipeline Events

  | Event | Triggered | Payload keys |
  |-------|-----------|--------------|
  | `:before_query` | First, before sanitization, preflight and execution | `:statement` (`%Lotus.Query.Statement{}`), `:source`, `:context`, `:vars` |
  | `:before_execute` | After sanitization and preflight pass, before execution | `:statement` (`%Lotus.Query.Statement{}`), `:relations`, `:source`, `:context`, `:vars` |
  | `:after_query` | After execution, before result returned to caller | `:result`, `:statement` (`%Lotus.Query.Statement{}`), `:source`, `:context`, `:vars` |
  | `:after_list_schemas` | After schema discovery and visibility filtering | `:schemas`, `:source`, `:scope`, `:context` |
  | `:after_list_tables` | After table discovery and visibility filtering | `:tables`, `:source`, `:scope`, `:context` |
  | `:after_describe_table` | After table schema introspection and column visibility | `:columns`, `:table_name`, `:schema`, `:source`, `:scope`, `:context` |
  | `:after_list_relations` | After relation discovery and visibility filtering | `:relations`, `:source`, `:scope`, `:context` |
  | `:after_discover` | After any discovery call, following the kind-specific `:after_list_*` event | `:kind`, `:result`, `:source`, `:scope`, `:context` |

  ### Query event ordering

  `:before_query` fires first, before sanitization and preflight, because a
  plug may rewrite the statement — row-level security and tenant predicates
  are the point of the hook. Sanitization and preflight then apply to what
  will actually execute.

  `:before_execute` fires after sanitization and preflight pass and before the
  statement executes. Its `:statement` is the rewritten one, and its
  `:relations` is what preflight proved the statement touches. The two hooks
  answer different questions: `:before_query` asks which statement should run,
  `:before_execute` asks whether the statement may proceed given what it
  provably touches.

  #### The `:relations` payload

  `:relations` is a list of `{schema, table}` tuples, where `schema` is `nil`
  for a source that has no schemas. Two values mean "Lotus cannot name the
  tables", not "the statement touches none":

    * `[]` — the adapter's `needs_preflight?/2` returned false for this
      statement, so no analysis ran.
    * `{:unrestricted, reason}` — the adapter cannot name the relations a
      statement touches (Elasticsearch, for one), and the host opted in via
      `:allow_unrestricted_resources`.

  A plug that authorizes on the table list must treat both as unknown and
  halt, rather than read them as an empty set of tables.

  `:vars` is the map of bound query variables, by name, after defaults and
  caller-supplied values are merged (`%{"start_date" => "2026-01-01"}`).
  It is `%{}` for a raw statement run through `Lotus.run_statement/3`. A plug
  can enforce rules on the values a caller picked (date-range limits, tenant
  checks) without parsing the statement.

  ### Caching

  `:before_query` and `:after_query` run **outside** the result cache callback —
  only the raw execution is cached. Both events therefore fire on a cache hit,
  and context-dependent middleware (per-user access control, audit) is safe to
  use without keying the cache on `:context`. A `:before_query` plug that
  rewrites the statement keys its own entry, because the rewritten statement is
  what builds the key. What an `:after_query` plug makes of the result goes to
  that caller and is not written back to the cache.

  `:before_execute` runs **inside** the callback, alongside the preflight whose
  relations it carries, so a cache hit skips it. A plug that must run on every
  call belongs on `:before_query`.

  ### Discovery event ordering

  Discovery calls (`Lotus.list_schemas/2`, `list_tables/2`, `describe_table/3`,
  `list_relations/2`) fire two events each:

  1. The kind-specific event (`:after_list_schemas`, `:after_list_tables`,
     `:after_describe_table`, or `:after_list_relations`) — receives the
     kind-specific payload with a key matching the returned value.
  2. The unified `:after_discover` event — receives a uniform payload
     `%{kind:, source:, result:, context:}` so a single middleware module can
     handle every discovery kind by dispatching on `:kind`.

  If any middleware in either phase halts, later middleware do not run and
  the caller receives `{:error, reason}`.

  ## Configuration

      config :lotus,
        middleware: %{
          before_query: [
            {MyApp.AccessControlPlug, []},
            {MyApp.QueryAuditPlug, [repo: MyApp.AuditRepo]}
          ],
          after_query: [
            {MyApp.QueryAuditPlug, [repo: MyApp.AuditRepo]}
          ],
          after_list_tables: [
            {MyApp.TableFilterPlug, []}
          ]
        }

  ## Context

  A `:context` key carries opaque user data (e.g. the current user) through
  to middleware. Lotus never inspects this value.
  """

  @persistent_term_key {__MODULE__, :compiled}

  @type event ::
          :before_query
          | :before_execute
          | :after_query
          | :after_list_schemas
          | :after_list_tables
          | :after_describe_table
          | :after_list_relations
          | :after_discover

  @type discover_kind ::
          :list_schemas
          | :list_tables
          | :describe_table
          | :list_relations
  @type middleware_spec :: {module(), keyword()}
  @type compiled_entry :: {module(), term()}
  @type pipeline_result :: {:cont, map()} | {:halt, term()}

  @doc """
  Compiles all middleware by calling `init/1` on each module and stores
  the result in `:persistent_term` for fast runtime access.

  An empty config clears the compiled pipeline, so reloading a config that
  no longer declares middleware actually turns it off.
  """
  @spec compile(map()) :: :ok
  def compile(middleware_config) when is_map(middleware_config) and middleware_config != %{} do
    compiled =
      Map.new(middleware_config, fn {event, plugs} ->
        entries =
          Enum.map(plugs, fn {mod, opts} ->
            {mod, mod.init(opts)}
          end)

        {event, entries}
      end)

    :persistent_term.put(@persistent_term_key, compiled)
  end

  def compile(_) do
    :persistent_term.erase(@persistent_term_key)
    :ok
  end

  @doc """
  Runs the middleware pipeline for the given event.

  Returns `{:cont, payload}` if all middleware passed, or
  `{:halt, reason}` if any middleware halted the pipeline.

  When no middleware is configured for the event, returns `{:cont, payload}`
  with zero overhead beyond the map lookup.
  """
  @spec run(event(), map()) :: {:cont, map()} | {:halt, term()}
  def run(event, payload) do
    case compiled_pipeline(event) do
      [] -> {:cont, payload}
      entries -> run_pipeline(entries, payload)
    end
  end

  defp run_pipeline([], payload), do: {:cont, payload}

  defp run_pipeline([{mod, compiled_opts} | rest], payload) do
    result =
      try do
        mod.call(payload, compiled_opts)
      rescue
        e -> {:halt, e}
      end

    case result do
      {:cont, new_payload} -> run_pipeline(rest, new_payload)
      {:halt, reason} -> {:halt, reason}
    end
  end

  @doc false
  def compiled_pipeline(event) do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil -> []
      compiled -> Map.get(compiled, event, [])
    end
  end
end
