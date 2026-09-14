defmodule Lotus.Middleware do
  @moduledoc """
  Generic middleware pipeline for query execution, schema discovery and content
  change hooks.

  Each middleware module implements `init/1` and `call/2`, following
  the standard Plug pattern:

      defmodule MyApp.AuditPlug do
        def init(opts), do: opts

        def call(payload, opts) do
          {:cont, payload}   # continue to next middleware
          # or
          {:halt, "reason"}  # stop pipeline, the caller gets an error tuple
        end
      end

  ## Pipeline Events

  | Event | Triggered | Payload keys |
  |-------|-----------|--------------|
  | `:before_query` | First, before sanitization, preflight and execution | `:statement` (`%Lotus.Query.Statement{}`), `:source`, `:context`, `:vars` |
  | `:before_execute` | After sanitization and preflight pass, before execution — or, on a cache hit, before the stored result is returned | `:statement` (`%Lotus.Query.Statement{}`), `:relations`, `:origin`, `:source`, `:context`, `:vars` |
  | `:after_query` | After execution, before result returned to caller | `:result`, `:statement` (`%Lotus.Query.Statement{}`), `:relations`, `:origin`, `:source`, `:context`, `:vars` |
  | `:after_list_schemas` | After schema discovery and visibility filtering | `:schemas`, `:source`, `:scope`, `:context` |
  | `:after_list_tables` | After table discovery and visibility filtering | `:tables`, `:source`, `:scope`, `:context` |
  | `:after_describe_table` | After table schema introspection and column visibility | `:columns`, `:table_name`, `:schema`, `:source`, `:scope`, `:context` |
  | `:after_list_relations` | After relation discovery and visibility filtering | `:relations`, `:source`, `:scope`, `:context` |
  | `:after_discover` | After any discovery call, following the kind-specific `:after_list_*` event | `:kind`, `:result`, `:source`, `:scope`, `:context` |
  | `:before_content_change` | Before a query, visualization, dashboard, card, filter or filter mapping is created, updated, deleted, shared or reordered | `:op`, `:resource`, `:record`, `:changeset`, `:context` |
  | `:after_content_change` | After that change is written | `:op`, `:resource`, `:record`, `:changes`, `:context` |

  ### Query event ordering

  `:before_query` fires first, before sanitization and preflight, because a
  plug may rewrite the statement — row-level security and tenant predicates
  are the point of the hook. Sanitization and preflight then apply to what
  will actually execute.

  `:before_execute` fires after sanitization and preflight pass and before the
  statement executes. Its `:statement` is the rewritten one, and its
  `:relations` is what preflight proved the statement touches — read back from
  the cache entry when the result is served from the cache. The two hooks
  answer different questions: `:before_query` asks which statement should run,
  `:before_execute` asks whether the statement may proceed given what it
  provably touches.

  #### The `:relations` payload

  `:relations` is what preflight knows about the statement. `:before_execute`
  and `:after_query` carry the same value.

    * A list of `{schema, table}` tuples, where `schema` is `nil` for a
      source that has no schemas, is the set preflight proved the statement
      touches. An empty list means it touches no relation — `SELECT 1`.
    * `{:unrestricted, reason}` — the adapter cannot name the relations a
      statement touches (Elasticsearch, for one), and the host opted in via
      `:allow_unrestricted_resources`.
    * `{:skipped, reason}` — the adapter does not preflight this statement
      (the SQL adapters skip `EXPLAIN`, `SHOW` and `PRAGMA`), so nothing was
      analysed.

  The two tuples mean "unknown". A plug that authorizes on the table list
  matches `when is_list(relations)` and halts on anything else, rather than
  read a tuple as an empty set of tables.

  #### The `:origin` payload

  `:origin` is `:executed` when the result came from the source on this call
  and `:cached` when it was served from the result cache. Both events carry
  it, so a plug that meters usage or cost can tell a read from an execution.

  #### Derived statements

  `window: [count: :exact]` runs a second statement, derived from the page
  statement, to compute `meta.total_count`. That run carries the caller's
  `:context`, `:vars`, `:scope` and read-only setting, and fires
  `:before_execute` — it touches the same tables as the page and is
  authorised the same way. It does not fire `:before_query`, because it is
  derived from the statement that hook already returned and a rewriting plug
  would apply twice. It does not fire `:after_query`, because it has no result
  the caller reads. A halt on the count run leaves `meta.total_count` as `nil`
  and the page result intact.

  `:vars` is the map of bound query variables, by name, after defaults and
  caller-supplied values are merged (`%{"start_date" => "2026-01-01"}`).
  It is `%{}` for a raw statement run through `Lotus.run_statement/3`. A plug
  can enforce rules on the values a caller picked (date-range limits, tenant
  checks) without parsing the statement.

  ### Caching

  Every query event fires on a cache hit. Only the raw execution is cached, and
  the relations preflight found are stored with it, so `:before_execute` carries
  them whether the result came from the source or from the cache. Middleware is
  therefore safe to make context-dependent — per-user access control, audit —
  without keying the cache on `:context`.

  A `:before_query` plug that rewrites the statement keys its own entry: the
  event runs before pagination and before the key is built, so the body, the
  bound values and the window all describe what will execute. What an
  `:after_query` plug makes of the result goes to that caller and is not written
  back; a halt there withholds the result from that caller, and the rows stay
  cached for one whose plugs let them through.

  What a hit does skip is the work between sanitization and the rows: statement
  sanitization, preflight table authorization, and column visibility. Those read
  `:scope`, which is part of the cache key — so a visibility resolver must
  decide from `(source, relations, column, scope)` alone. Per-actor logic that
  cannot be expressed that way belongs in middleware.

  ### Observing a run

  Middleware decides; it does not observe. A halt in `:before_query` or
  `:before_execute` means `:after_query` never fires, so a plug there cannot
  see a refusal, and a plug sees only the calls its own event covers. The
  `[:lotus, :run, :start | :stop | :exception]` telemetry events bracket the
  whole run instead — every phase, on a cache hit and on a halt alike — and
  carry the caller's `:context`, the relations, the origin and, on failure,
  the phase that failed. An audit or usage consumer attaches to those. See
  `Lotus.Telemetry`.

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

  ### Content change events

  Every create, update and delete of a query, visualization, dashboard,
  dashboard card, dashboard filter or filter mapping fires
  `:before_content_change` and then, when the change is written,
  `:after_content_change`. So do reordering dashboard cards and enabling or
  disabling public sharing. The mutation functions in `Lotus`, `Lotus.Storage`,
  `Lotus.Dashboards` and `Lotus.Viz` take `opts` with a `:context`, as
  `Lotus.run_query/2` does.

    * `:op` is `:create`, `:update`, `:delete`, `:enable_sharing` or
      `:disable_sharing`.
    * `:resource` is `:query`, `:visualization`, `:dashboard`,
      `:dashboard_card`, `:dashboard_filter` or `:filter_mapping`.
    * `:record` is the struct as stored on `:before_content_change`, or `nil`
      on a create, and the struct as written on `:after_content_change`.
    * `:changeset` is the `Ecto.Changeset` Lotus is about to write. On a delete
      it has no changes.
    * `:changes` maps each changed field to its written value, embedded fields
      included. It is `%{}` on a delete.

  `:before_content_change` fires whether or not the changeset is valid, so a
  refusal does not first tell the caller what is wrong with the input. A halt
  makes the mutation function return `{:error, {:halted, reason}}` and nothing
  is written. The `:halted` tag keeps a refusal apart from
  `{:error, %Ecto.Changeset{}}` and `{:error, :not_found}`, which the same
  functions already return. A plug may not change the changeset: Lotus writes
  the changeset it built.

  #### Public sharing

  `Lotus.enable_public_sharing/2` fires `:enable_sharing` and
  `Lotus.disable_public_sharing/2` fires `:disable_sharing`, both on
  `:dashboard` with `:public_token` in the changes. On `:enable_sharing`,
  `:record` holds the token as stored: `nil` for a first enable, the previous
  token for a rotation. `:public_token` is still a field
  `Lotus.update_dashboard/3` accepts, and setting it there is an `:update`
  whose changes carry it, so a plug that refuses sharing checks both.

  #### Reordering cards

  `Lotus.reorder_dashboard_cards/3` fires one `:update` of `:dashboard_card`
  for each card whose position changes, with `:position` in the changes. Every
  `:before_content_change` runs before any position is written, so a halt on
  one card leaves every position as it was. The positions are written in one
  transaction, and `:after_content_change` fires for each card after it
  commits.

  #### After the write

  `:after_content_change` fires after the change is written. An update whose
  changeset has no changes writes nothing and fires no `:after_content_change`.
  The write has happened, so the event cannot stop it: a plug that halts,
  raises, throws or exits is logged, the later plugs on the event do not run,
  and the caller still receives `{:ok, record}`. The event fires when the write
  returns, or for a reorder when its transaction commits. If the caller wraps
  the call in its own transaction, that transaction has not committed yet.

  #### Deletes that remove other content

  A delete fires one event, for the record it names. The content removed with
  it fires none, so the parent's `:delete` is the event to gate and to record.

    * Deleting a dashboard deletes its cards, its filters and their filter
      mappings.
    * Deleting a card or a filter deletes its filter mappings.
    * Deleting a query deletes its visualizations, and sets `query_id` to `nil`
      on every dashboard card that showed it.

  A delete by id that finds no record returns `{:error, :not_found}` and fires
  no event.

  #### Observing content changes

  The `[:lotus, :content, :change, :start | :stop | :exception]` telemetry
  events bracket every content change, refused or not. `:stop` carries the
  `:after_content_change` metadata and is emitted for an update that wrote
  nothing, too. `:exception` carries the reason the caller receives:
  `{:halted, reason}` for a refusal, the changeset for a failed validation.
  See `Lotus.Telemetry`.

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
          | :before_content_change
          | :after_content_change

  @typedoc """
  The error reason a mutation function returns when a `:before_content_change`
  plug halts, wrapping the reason the plug gave.
  """
  @type halted :: {:halted, term()}

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
