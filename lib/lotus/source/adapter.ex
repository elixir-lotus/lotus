defmodule Lotus.Source.Adapter do
  @moduledoc """
  Behaviour and struct for database adapters in Lotus.

  An adapter wraps a data source behind a uniform interface. Instead of passing
  raw Ecto.Repo modules throughout the pipeline, consumers work with an
  `%Adapter{}` struct that carries:

    * `name`        — a human-readable identifier (e.g. `"main"`, `"warehouse"`)
    * `module`      — the module implementing this behaviour
    * `state`       — opaque connection state managed by the adapter
    * `source_type` — an atom identifying the database kind (`:postgres`, `:mysql`, etc.)
    * `capabilities` — the capability behaviours `module` declares (see below)

  ## Implementing an adapter

  This module is the core behaviour. Its nine required callbacks are what
  every source needs:

    * **Query execution** — `execute_query/4`, `transaction/3`
    * **Introspection** — `list_tables/3`, `describe_table/3`
    * **Safety** — `builtin_denies/1`
    * **Lifecycle** — `health_check/1`, `disconnect/1`
    * **Error handling** — `format_error/2`
    * **Source identity** — `source_type/1`

  Its optional callbacks are `supports_feature?/2`, the registration
  callbacks `can_handle?/1` and `wrap/2`, and the process callbacks
  `shared_children/0`, `source_children/2`, `source_started/2` and
  `source_stopped/2`.

  Everything else belongs to a capability behaviour, which groups the
  callbacks that only make sense together. An adapter declares the ones its
  source supports and implements every callback of each:

    * `Lotus.Source.Adapter.Introspection` — schemas, namespace resolution,
      statistics, qualified names and identifier validation
    * `Lotus.Source.Adapter.Preflight` — safety checks, accessed resources,
      validation and query plans
    * `Lotus.Source.Adapter.Binding` — `{{var}}` binding and type mapping
    * `Lotus.Source.Adapter.Shaping` — filters, sorts, pagination, limits
      and identifier quoting
    * `Lotus.Source.Adapter.Editor` — editor configuration, query language,
      example queries and AI context

  For example, a search engine adapter that filters and sorts but has no
  schemas:

      defmodule MyApp.Adapters.Search do
        @behaviour Lotus.Source.Adapter
        @behaviour Lotus.Source.Adapter.Preflight
        @behaviour Lotus.Source.Adapter.Shaping
        @behaviour Lotus.Source.Adapter.Editor
        # ...
      end

  The dispatch helpers below call a capability's callbacks only when the
  adapter declares its behaviour, and use a default otherwise. Exporting
  `apply_filters/3` without `@behaviour Lotus.Source.Adapter.Shaping` is
  not enough: Lotus ignores it and logs a warning. `capabilities/1` says
  what an adapter declares, and `mix lotus.adapter.check` lists it with
  what is missing. `use Lotus.Source.Adapters.Ecto` declares every
  capability.

  The `:capabilities` field of `%Adapter{}` holds the declared
  capabilities. `with_capabilities/1` fills it when the adapter is built,
  so dispatch reads the struct instead of the module.

  ## Pipeline Statement contract

  All pipeline callbacks operate on a `%Lotus.Query.Statement{}` struct that
  carries the adapter-native payload (`:body`, an opaque term), `:params`, and
  adapter-specific `:meta`. Adapters return a new statement with the relevant
  field updated — the pipeline is a series of pure `statement -> statement`
  transforms.

  Introspection callbacks consistently return `{:ok, result} | {:error, reason}`
  tuples so callers can handle failures uniformly.

  ## Relations are two-level

  Everywhere Lotus names a resource it uses exactly two levels:
  `{schema | nil, table}`. That shape is fixed — visibility rules, deny
  lists, `describe_table/3`, `resolve_table_namespace/3`, the preflight
  relation set and `extract_accessed_resources/2` all speak it, and core
  never grows a third element.

  `nil` in the first position means "unqualified" — a source with no
  namespace concept at all (SQLite tables, Elasticsearch indices), or a
  name the caller left unqualified.

  Engines with a **deeper** hierarchy flatten everything above the leaf
  into the schema part, keeping the separator their own query language
  uses:

    * BigQuery `project.dataset.table` → `{"project.dataset", "table"}`
    * A catalog/schema/table engine → `{"catalog.schema", "table"}`

  Adapters own that flattening in `parse_qualified_name/2` and
  `resolve_table_namespace/3`; core treats the schema part as an opaque
  string and compares it verbatim against visibility rules. The practical
  consequence for adapter authors: a deny rule the host writes must match
  the flattened form your adapter produces, so document the spelling your
  adapter emits.

  ## Dispatch helpers

  This module provides convenience functions that accept an `%Adapter{}` struct
  and delegate to the underlying module, passing `state` where needed:

      adapter = %Adapter{name: "main", module: MyPostgres, state: conn, source_type: :postgres}

      Adapter.execute_query(adapter, "SELECT 1", [], [])
      Adapter.list_schemas(adapter)
      Adapter.quote_identifier(adapter, "users")
  """

  alias Lotus.Query.Filter
  alias Lotus.Query.Statement
  alias Lotus.Query.Tokenizer.Profile

  @type source_type :: :postgres | :mysql | :sqlite | :other | atom()

  @typedoc """
  The column a foreign key column references. `schema` is `nil` for a
  source without schemas; `column` is `nil` when the source does not say
  (SQLite's reference to the other table's primary key).
  """
  @type column_reference :: %{
          schema: String.t() | nil,
          table: String.t(),
          column: String.t() | nil
        }

  @typedoc """
  A column of `c:describe_table/3`. `:comment` (the column's comment in the
  database) and `:references` (the column it references, for a foreign key
  column) are optional: an adapter whose source has neither leaves them
  out.
  """
  @type column_def :: %{
          required(:name) => String.t(),
          required(:type) => String.t(),
          required(:nullable) => boolean(),
          required(:default) => String.t() | nil,
          required(:primary_key) => boolean(),
          optional(:comment) => String.t() | nil,
          optional(:references) => column_reference() | nil
        }

  @typedoc """
  A capability behaviour an adapter module declares, named by its last
  segment: `:introspection` is `Lotus.Source.Adapter.Introspection`.
  """
  @type capability :: :introspection | :preflight | :binding | :shaping | :editor

  @typedoc """
  What a statement cost the engine, as `execute_query/4` may report it. Every
  key is optional:

    * `:bytes_scanned` - Bytes the engine read
    * `:bytes_billed` - Bytes the engine charges for, when it rounds or has a
      minimum (BigQuery)
    * `:rows_scanned` - Rows the engine read, not the rows returned
    * `:credits` - Compute credits or another unit the engine bills in
  """
  @type cost :: %{
          optional(:bytes_scanned) => non_neg_integer(),
          optional(:bytes_billed) => non_neg_integer(),
          optional(:rows_scanned) => non_neg_integer(),
          optional(:credits) => number()
        }

  @typedoc "A capability and the behaviour that declares it."
  @type capability_behaviour ::
          {:introspection, Lotus.Source.Adapter.Introspection}
          | {:preflight, Lotus.Source.Adapter.Preflight}
          | {:binding, Lotus.Source.Adapter.Binding}
          | {:shaping, Lotus.Source.Adapter.Shaping}
          | {:editor, Lotus.Source.Adapter.Editor}

  @type t :: %__MODULE__{
          name: String.t(),
          module: module(),
          state: term(),
          source_type: source_type(),
          capabilities: [capability()] | nil
        }

  @enforce_keys [:name, :module, :source_type]
  defstruct [:name, :module, :state, :source_type, capabilities: nil]

  @capability_behaviours [
    introspection: Lotus.Source.Adapter.Introspection,
    preflight: Lotus.Source.Adapter.Preflight,
    binding: Lotus.Source.Adapter.Binding,
    shaping: Lotus.Source.Adapter.Shaping,
    editor: Lotus.Source.Adapter.Editor
  ]

  @capability_map Map.new(@capability_behaviours)

  # ---------------------------------------------------------------------------
  # Callbacks — Query Execution
  # ---------------------------------------------------------------------------

  @doc """
  Execute a prepared statement against the data source.

  This is the driver boundary: adapters receive the adapter-native statement
  payload (SQL text for Ecto, a JSON body for Elasticsearch, a DSL AST for
  other engines) together with any bound `params`, and return the usual
  `{columns, rows, num_rows}` result shape so core can assemble a
  `%Lotus.Result{}`.

  ## Optional `:total_count` — inline count strategy

  When the caller requested `count: :exact` via pagination and the adapter
  can compute the pre-pagination row total as a side-effect of running the
  main query (e.g. Elasticsearch's `hits.total.value` with
  `track_total_hits: true`), include `:total_count` in the result map:

      {:ok, %{
        columns: [...],
        rows: [...],
        num_rows: N,
        total_count: T    # pre-pagination total; nil if unavailable
      }}

  Adapters without a cheap inline count should omit the key and use
  `apply_pagination/3` + `:count_spec` to compute the total via a separate
  query. See the pagination callback for the full precedence rule.

  ## Optional `:cost` — what the statement cost the engine

  An engine that bills by work done (a warehouse that charges per byte
  scanned or in credits) can say what the statement cost by including
  `:cost` (see `t:cost/0`):

      {:ok, %{columns: [...], rows: [...], num_rows: N,
              cost: %{bytes_scanned: 52_428_800, bytes_billed: 52_428_800}}}

  Lotus keeps the keys it knows with non-negative values, puts them in the
  result's `meta.cost`, and adds them to the measurements of the
  `[:lotus, :query, :stop]` telemetry event. An adapter whose engine reports
  nothing omits the key.
  """
  @callback execute_query(state :: term(), sql :: term(), params :: list(), opts :: keyword()) ::
              {:ok,
               %{
                 :columns => [String.t()],
                 :rows => [[term()]],
                 :num_rows => non_neg_integer(),
                 optional(:total_count) => non_neg_integer() | nil,
                 optional(:cost) => cost()
               }}
              | {:error, term()}

  @doc "Execute a function within a transaction."
  @callback transaction(state :: term(), fun :: (term() -> any()), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  # ---------------------------------------------------------------------------
  # Callbacks — Introspection
  # ---------------------------------------------------------------------------

  @doc "List tables (and optionally views) in the given schemas."
  @callback list_tables(state :: term(), schemas :: [String.t()], opts :: keyword()) ::
              {:ok, [{schema :: String.t() | nil, table :: String.t()}]} | {:error, term()}

  @doc """
  Return column definitions for a specific table.

  Add `:comment` and `:references` to a column where the source has them:
  a model writing queries joins on foreign keys instead of guessing them
  from names. `Lotus.Schema.describe_table/3` drops a reference to a
  relation the caller may not see.
  """
  @callback describe_table(state :: term(), schema :: String.t() | nil, table :: String.t()) ::
              {:ok, [column_def()]} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Shared types
  # ---------------------------------------------------------------------------

  @typedoc """
  Optional count-query description placed in `statement.meta[:count_spec]` by
  `apply_pagination/3` when the caller requested `count: :exact`. Plain data:
  `:query` is the count payload (SQL text, JSON DSL, whatever the adapter's
  language calls "count this result set"), and `:params` are its bound
  parameters. Lotus core runs this through the same adapter the paginated
  statement ran through — the adapter does not need to remember its own
  identity.
  """
  @type count_spec :: %{query: term(), params: list()}

  @typedoc """
  Per-AI-feature capability declaration. Adapters use this to declare
  which AI features they actually support — `Lotus.AI.supports?/2`
  reads it directly to let UIs gate per-source button visibility.

    * `true` — feature supported.
    * `{false, reason}` — feature unsupported; the reason is surfaced
      to users. For untrusted adapters, reasons are replaced with a
      generic fallback at the dispatch layer.

  Default (when the `:capabilities` key is absent from `ai_context_map`):
  all three features `true` — existing adapters inherit the permissive
  behavior without needing to declare anything.
  """
  @type ai_capability :: true | {false, String.t()}

  @type ai_capabilities :: %{
          generation: ai_capability(),
          optimization: ai_capability(),
          explanation: ai_capability()
        }

  @typedoc """
  Structured, bounded context an adapter supplies to the AI pipeline.

  Fixed keys; free-form fields are length-capped at the dispatch layer
  to bound blast radius from a compromised or noisy adapter. See
  `Lotus.Source.Adapter.ai_context/1` dispatch for exact limits.

  The optional `:capabilities` map declares per-feature AI support.
  """
  @type ai_context_map :: %{
          required(:language) => String.t(),
          required(:example_query) => String.t(),
          required(:syntax_notes) => String.t(),
          required(:error_patterns) => [%{pattern: Regex.t(), hint: String.t()}],
          optional(:generation_notes) => String.t(),
          optional(:read_only_notes) => String.t(),
          optional(:capabilities) => ai_capabilities()
        }

  @typedoc """
  Optional SQL tokenizer spec, passed through verbatim (camelCased) to
  CodeMirror 6's `SQLDialect.define()` so external SQL adapters can reach
  tokenization parity with the built-in PG / MySQL Lezer grammars.

  Field names mirror `@codemirror/lang-sql`'s `SQLDialectSpec` — see
  `assets/node_modules/@codemirror/lang-sql/dist/index.d.ts` in
  `lotus_web` for authoritative semantics.
  """
  @type dialect_spec :: %{
          optional(:identifier_quotes) => String.t(),
          optional(:operator_chars) => String.t(),
          optional(:hash_comments) => boolean(),
          optional(:slash_comments) => boolean(),
          optional(:double_quoted_strings) => boolean(),
          optional(:double_dollar_quoted_strings) => boolean(),
          optional(:backslash_escapes) => boolean(),
          optional(:space_after_dashes) => boolean(),
          optional(:case_insensitive_identifiers) => boolean(),
          optional(:builtin) => String.t(),
          optional(:char_set_casts) => boolean(),
          optional(:plsql_quoting_mechanism) => boolean(),
          optional(:unquoted_bit_literals) => boolean(),
          optional(:treat_bits_as_bytes) => boolean(),
          optional(:special_var) => String.t()
        }

  @typedoc """
  Structural JSON DSL schema used by `lotus_web`'s `JsonDslCompletion` to
  offer parent-aware completions (e.g., only `must`/`should`/`filter`
  inside Elasticsearch's `bool` block; field names from the schema
  inside `match`/`term`/`range`).

  * `:root` — valid top-level keys.
  * `:children` — per-parent-key rules. Values are either a list of valid
    child keys, or one of the marker atoms `:fields` (use schema field
    names), `:array_of_query` (array element objects accept the same
    keys as `"query"`), `:named_aggregation` (user-named bucket — no
    key suggestions), or `:range_operators` (grandparent lookup for ES
    range-style operators).
  * `:value_literals` — fixed value-position completions keyed by
    immediate key (e.g., `"order" => ["asc", "desc"]`).
  """
  @type context_schema :: %{
          required(:root) => [String.t()],
          required(:children) => %{
            String.t() => [String.t()] | atom() | [{String.t(), atom()}]
          },
          optional(:value_literals) => %{String.t() => [String.t()]}
        }

  # ---------------------------------------------------------------------------
  # Callbacks — Safety
  # ---------------------------------------------------------------------------

  @doc "Return built-in deny rules for system tables (list of `{schema_pattern, table_pattern}` tuples)."
  @callback builtin_denies(state :: term()) ::
              [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]

  # ---------------------------------------------------------------------------
  # Callbacks — Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Check that the data source is reachable.

  Must work for a source whose processes are not running yet, so a UI can
  test a connection before the source is saved. An adapter that pools
  connections through `source_children/2` makes a one-off connection here
  when `Lotus.Source.Registry.whereis/2` returns `nil`.
  """
  @callback health_check(state :: term()) :: :ok | {:error, term()}

  @doc "Disconnect from the data source and release resources."
  @callback disconnect(state :: term()) :: :ok

  @typedoc "A child spec as `Supervisor.start_link/2` accepts it."
  @type child_spec :: Supervisor.child_spec() | {module(), term()} | module()

  @doc """
  Processes the adapter needs once, however many sources it has.

  Started under `Lotus.Source.Supervisor` when the first source of this
  module appears and stopped when the last one goes. An HTTP adapter puts
  its `Finch` instance here, since a Finch name must be an atom and its
  pools are added per URL as sources come and go.

  Optional. Defaults to no children.
  """
  @callback shared_children() :: [child_spec()]

  @doc """
  Processes the adapter needs for one source.

  Started under `Lotus.Source.Supervisor` when the source appears or when
  its state changes, and stopped when it goes. A pool that takes a name
  registers it through `Lotus.Source.Registry.via/2`, so no atom is minted
  per source. A dynamic Ecto repo, a `DBConnection` pool and a `NimblePool`
  of NIF handles all belong here.

  Children run under a supervisor of their own per source, so a source
  crashing past its restart limit does not affect the others.

  Optional. Defaults to no children.
  """
  @callback source_children(name :: String.t(), state :: term()) :: [child_spec()]

  @doc """
  Called after the children of a source are up.

  Adapters that add a source to shared infrastructure instead of owning a
  process use this hook: an HTTP adapter calls `Finch.start_pool/3` with the
  source URL here. Raising or exiting counts as a failed start: the
  source's children are stopped and the source is tried again on the next
  reconcile.

  Optional. Defaults to `:ok`.
  """
  @callback source_started(name :: String.t(), state :: term()) :: :ok

  @doc """
  Called before the children of a source are stopped, with the state the
  source was started with.

  Optional. Defaults to `:ok`.
  """
  @callback source_stopped(name :: String.t(), state :: term()) :: :ok

  # ---------------------------------------------------------------------------
  # Callbacks — Error Handling
  # ---------------------------------------------------------------------------

  @doc """
  Format a data-source error into a human-readable string.

  Adapters translate driver-specific exceptions (e.g. `Postgrex.Error`,
  `MyXQL.Error`, or a non-SQL engine's error struct) into a user-facing
  message. Called from `Lotus.Runner` when the execution phase raises.
  """
  @callback format_error(state :: term(), any()) :: String.t()

  # ---------------------------------------------------------------------------
  # Callbacks — Source Identity
  # ---------------------------------------------------------------------------

  @doc "Return the source type atom (e.g. `:postgres`, `:mysql`)."
  @callback source_type(state :: term()) :: source_type()

  @typedoc """
  A capability an adapter may declare through `supports_feature?/2`.

  These are the atoms core and the built-in UI ask about. The type is open —
  an adapter may answer questions about its own atoms, and callers that
  invent one get `false` from any adapter that does not recognise it — but
  these are the ones with defined meaning:

    * `:schema_hierarchy` — the source has a real namespace level above
      tables, so the UI shows a schema picker. False for flat sources
      (SQLite, Elasticsearch); false for MySQL, whose databases are
      configured per source rather than browsed.

    * `:search_path` — the source honours a session-level namespace search
      path, so a caller-supplied `:search_path` option is meaningful.

    * `:arrays` — the query language has a first-class array type, so list
      variables can bind as one value instead of being expanded into N
      placeholders.

    * `:json` — the source can store and query JSON documents, which the
      editor uses to offer JSON-aware affordances.

    * `:make_interval` — SQL-specific: the engine has a `make_interval`
      function, so the transformer can rewrite `INTERVAL '{{n}} days'`
      into a parameterized call instead of inlining the value.

    * `:dynamic_options` — a query against this source can return a flat
      list of values suitable for populating a variable's dropdown, so the
      UI offers query-based option population alongside manual entry. True
      for every SQL source. False for sources whose query language returns
      shaped documents rather than rows (Elasticsearch), where the user
      enters dropdown options by hand.

  Answer `false` for anything you do not recognise; the built-in dialects
  all end with a catch-all clause that does exactly that.
  """
  @type feature ::
          :schema_hierarchy
          | :search_path
          | :arrays
          | :json
          | :make_interval
          | :dynamic_options
          | atom()

  @doc """
  Whether this adapter supports a given feature.

  See `t:feature/0` for the atoms core asks about and what each one means.
  """
  @callback supports_feature?(state :: term(), feature()) :: boolean()

  # ---------------------------------------------------------------------------
  # Callbacks — Pluggable Registration
  # ---------------------------------------------------------------------------

  @doc "Whether this adapter can handle the given data source entry (e.g. a repo module)."
  @callback can_handle?(term()) :: boolean()

  @doc "Wrap a raw data source entry into an `%Adapter{}` struct."
  @callback wrap(name :: String.t(), term()) :: t()

  @optional_callbacks [
    can_handle?: 1,
    wrap: 2,
    supports_feature?: 2,
    shared_children: 0,
    source_children: 2,
    source_started: 2,
    source_stopped: 2
  ]

  # Conservative fallback deny rules applied when no adapter can be resolved
  # for a source name (e.g., typo'd repo, unconfigured source). Owned here so
  # generic cross-cutting modules like `Lotus.Visibility` don't need to reach
  # into the Ecto subtree for a sensible default. Built-in Ecto dialects
  # (Postgres, MySQL, SQLite) override these via their own callbacks.
  @fallback_table_denies [
    {"pg_catalog", ~r/.*/},
    {"information_schema", ~r/.*/},
    {nil, ~r/^sqlite_/},
    {nil, "schema_migrations"},
    {"public", "schema_migrations"},
    {"public", "lotus_queries"},
    {nil, "lotus_queries"},
    {"public", "lotus_query_visualizations"},
    {nil, "lotus_query_visualizations"},
    {"public", "lotus_dashboards"},
    {nil, "lotus_dashboards"},
    {"public", "lotus_dashboard_cards"},
    {nil, "lotus_dashboard_cards"},
    {"public", "lotus_dashboard_filters"},
    {nil, "lotus_dashboard_filters"},
    {"public", "lotus_dashboard_card_filter_mappings"},
    {nil, "lotus_dashboard_card_filter_mappings"}
  ]

  @fallback_schema_denies [
    "pg_catalog",
    "information_schema",
    "mysql",
    "performance_schema",
    "sys"
  ]

  # Tables that Lotus's companions own, in any schema or none: Lotus Pro's
  # policies and migrations, and the tables of Sake, which Lotus.MCP runs on:
  # its OAuth tables and `sake_tasks`. They hold policies, token hashes and
  # other people's task results, never data to report on.
  # Not a `^lotus_` pattern: Lotus's own SQL aliases a subquery `lotus_sub`, and
  # SQLite's preflight reads that alias as a table.
  @owned_table_denies [
    "lotus_access_policies",
    "lotus_pro_migrations",
    {~r/.*/, ~r/^sake_oauth_/},
    {nil, ~r/^sake_oauth_/},
    {~r/.*/, ~r/^sake_tasks$/},
    {nil, ~r/^sake_tasks$/}
  ]

  @doc """
  Table-level deny rules for the tables Lotus's companions own: Lotus Pro's
  (`lotus_access_policies`, `lotus_pro_migrations`), every `sake_oauth_`
  table (the OAuth server of `Lotus.MCP`) and `sake_tasks` (where Sake keeps
  MCP task results), in any schema.

  `Lotus.Visibility` adds them to every source, whatever its adapter and the
  host's rules, so no adapter needs to list them. Lotus's own tables stay in
  each adapter's `builtin_denies/1`.
  """
  @spec owned_table_denies() :: [String.t() | {nil | Regex.t(), Regex.t()}]
  def owned_table_denies, do: @owned_table_denies

  @doc """
  Built-in table-level deny rules to apply when no adapter can be resolved.

  Returns a conservative shotgun-union list covering Postgres, MySQL, and
  SQLite system-schema patterns plus Lotus's own storage tables. Callers with
  an `%Adapter{}` struct should prefer `builtin_denies/1` (the struct dispatch
  helper), which routes to the adapter's own rules.
  """
  @spec builtin_denies() :: [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]
  def builtin_denies, do: @fallback_table_denies

  @doc """
  Built-in schema-level deny patterns to apply when no adapter can be resolved.

  Callers with an `%Adapter{}` struct should prefer `builtin_schema_denies/1`.
  """
  @spec builtin_schema_denies() :: [String.t() | Regex.t()]
  def builtin_schema_denies, do: @fallback_schema_denies

  # ---------------------------------------------------------------------------
  # Capabilities
  # ---------------------------------------------------------------------------

  @doc """
  The capability behaviours, as `{capability, behaviour}` pairs.
  """
  @spec capability_behaviours() :: [capability_behaviour(), ...]
  def capability_behaviours, do: @capability_behaviours

  @doc """
  The capabilities of an adapter.

  Given an `%Adapter{}`, returns its `:capabilities` field, or the
  capabilities of its module when the field is `nil` (a struct built by
  hand rather than through `with_capabilities/1`). Given a module, returns
  the capability behaviours it declares with `@behaviour`, in the order of
  `capability_behaviours/0`.

  A module that exports the callbacks of a capability without declaring
  its behaviour does not get that capability. A warning is logged once per
  module and capability when that happens.
  """
  @spec capabilities(t() | module()) :: [capability()]
  def capabilities(%__MODULE__{capabilities: caps}) when is_list(caps), do: caps
  def capabilities(%__MODULE__{module: mod}), do: capabilities(mod)

  def capabilities(mod) when is_atom(mod) do
    declared = declared_behaviours(mod)

    for {cap, behaviour} <- @capability_behaviours,
        declared?(mod, cap, behaviour, declared),
        do: cap
  end

  @doc """
  Whether the adapter has the given capability.
  """
  @spec capability?(t() | module(), capability()) :: boolean()
  def capability?(adapter_or_module, capability)
      when is_map_key(@capability_map, capability) do
    capability in capabilities(adapter_or_module)
  end

  @doc """
  Fill the `:capabilities` field of an adapter from its module, so dispatch
  reads it from the struct instead of the module's attributes.

  `Lotus.Source.Resolvers.Static` and the built-in Ecto adapters call it on
  every adapter they build. A custom resolver or `wrap/2` can call it too;
  an adapter without it still works, at the cost of reading the module's
  attributes on each dispatch.
  """
  @spec with_capabilities(t()) :: t()
  def with_capabilities(%__MODULE__{capabilities: caps} = adapter) when is_list(caps),
    do: adapter

  def with_capabilities(%__MODULE__{module: mod} = adapter),
    do: %{adapter | capabilities: capabilities(mod)}

  defp has?(%__MODULE__{} = adapter, capability), do: capability in capabilities(adapter)

  defp declared_behaviours(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :module_info, 1) do
      mod.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
    else
      []
    end
  end

  defp declared?(mod, cap, behaviour, declared) do
    if behaviour in declared do
      true
    else
      if exports_any_callback?(mod, behaviour), do: warn_undeclared_once(mod, cap, behaviour)
      false
    end
  end

  @doc false
  def exports_any_callback?(mod, behaviour) do
    Enum.any?(behaviour.behaviour_info(:callbacks), fn {fun, arity} ->
      function_exported?(mod, fun, arity)
    end)
  end

  defp warn_undeclared_once(mod, cap, behaviour) do
    key = {__MODULE__, :undeclared_capability, mod, cap}

    case :persistent_term.get(key, :none) do
      :warned ->
        :ok

      :none ->
        :persistent_term.put(key, :warned)
        require Logger

        Logger.warning(
          "#{inspect(mod)} exports #{inspect(behaviour)} callbacks but does not declare " <>
            "`@behaviour #{inspect(behaviour)}`; Lotus ignores them. Run " <>
            "`mix lotus.adapter.check #{inspect(mod)}` for details."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch helpers — stateful (pass adapter.state as first arg)
  # ---------------------------------------------------------------------------

  @doc "Execute a SQL query via the adapter."
  @spec execute_query(t(), String.t(), list(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_query(%__MODULE__{module: mod, state: state}, sql, params, opts) do
    mod.execute_query(state, sql, params, opts)
  end

  @doc "Execute a function within a transaction via the adapter."
  @spec transaction(t(), (term() -> any()), keyword()) :: {:ok, any()} | {:error, any()}
  def transaction(%__MODULE__{module: mod, state: state}, fun, opts) do
    mod.transaction(state, fun, opts)
  end

  @doc "List all schemas via the adapter."
  @spec list_schemas(t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_schemas(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :introspection),
      do: mod.list_schemas(state),
      else: {:ok, []}
  end

  @doc "List tables via the adapter."
  @spec list_tables(t(), [String.t()], keyword()) ::
          {:ok, [{String.t() | nil, String.t()}]} | {:error, term()}
  def list_tables(%__MODULE__{module: mod, state: state}, schemas, opts) do
    mod.list_tables(state, schemas, opts)
  end

  @doc "Get column definitions for a table via the adapter."
  @spec describe_table(t(), String.t() | nil, String.t()) ::
          {:ok, [column_def()]} | {:error, term()}
  def describe_table(%__MODULE__{module: mod, state: state}, schema, table) do
    mod.describe_table(state, schema, table)
  end

  @doc "Resolve which schema contains a table via the adapter."
  @spec resolve_table_namespace(t(), String.t(), [String.t()]) ::
          {:ok, String.t() | nil} | {:error, term()}
  def resolve_table_namespace(%__MODULE__{module: mod, state: state} = adapter, table, schemas) do
    if has?(adapter, :introspection),
      do: mod.resolve_table_namespace(state, table, schemas),
      else: {:ok, nil}
  end

  @doc "Get the execution plan for a statement via the adapter."
  @spec query_plan(t(), Statement.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def query_plan(%__MODULE__{module: mod, state: state} = adapter, %Statement{} = statement, opts) do
    if has?(adapter, :preflight),
      do: mod.query_plan(state, statement, opts),
      else: {:ok, nil}
  end

  @doc "Return built-in deny rules via the adapter."
  @spec builtin_denies(t()) :: [{String.t() | nil | Regex.t(), String.t() | Regex.t()}]
  def builtin_denies(%__MODULE__{module: mod, state: state}) do
    mod.builtin_denies(state)
  end

  @doc "Return built-in schema denies via the adapter."
  @spec builtin_schema_denies(t()) :: [String.t() | Regex.t()]
  def builtin_schema_denies(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :introspection),
      do: mod.builtin_schema_denies(state),
      else: []
  end

  @doc "Return statistics for a relation via the adapter."
  @spec table_stats(t(), String.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def table_stats(%__MODULE__{module: mod, state: state} = adapter, schema, table) do
    if has?(adapter, :introspection) and function_exported?(mod, :table_stats, 3),
      do: mod.table_stats(state, schema, table),
      else: {:error, :unsupported}
  end

  @doc "Return row count estimates for the relations in `schemas` via the adapter."
  @spec table_row_estimates(t(), [String.t()]) ::
          {:ok, %{{String.t() | nil, String.t()} => non_neg_integer()}} | {:error, term()}
  def table_row_estimates(%__MODULE__{module: mod, state: state} = adapter, schemas) do
    if has?(adapter, :introspection) and function_exported?(mod, :table_row_estimates, 2),
      do: mod.table_row_estimates(state, schemas),
      else: {:error, :unsupported}
  end

  @doc "Return default schemas via the adapter."
  @spec default_schemas(t()) :: [String.t()]
  def default_schemas(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :introspection),
      do: mod.default_schemas(state),
      else: []
  end

  @doc "Check data source health via the adapter."
  @spec health_check(t()) :: :ok | {:error, term()}
  def health_check(%__MODULE__{module: mod, state: state}) do
    mod.health_check(state)
  end

  @doc "Disconnect from the data source via the adapter."
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{module: mod, state: state}) do
    mod.disconnect(state)
  end

  @doc "Children the adapter module needs once. `[]` if not implemented."
  @spec shared_children(module()) :: [child_spec()]
  def shared_children(mod) when is_atom(mod) do
    if function_exported?(mod, :shared_children, 0),
      do: mod.shared_children(),
      else: []
  end

  @doc "Children the adapter needs for this source. `[]` if not implemented."
  @spec source_children(t()) :: [child_spec()]
  def source_children(%__MODULE__{module: mod, name: name, state: state}) do
    if function_exported?(mod, :source_children, 2),
      do: mod.source_children(name, state),
      else: []
  end

  @doc "Tell the adapter this source's children are up. `:ok` if not implemented."
  @spec source_started(t()) :: :ok
  def source_started(%__MODULE__{module: mod, name: name, state: state}) do
    if function_exported?(mod, :source_started, 2),
      do: mod.source_started(name, state),
      else: :ok
  end

  @doc "Tell the adapter this source's children are about to stop. `:ok` if not implemented."
  @spec source_stopped(t()) :: :ok
  def source_stopped(%__MODULE__{module: mod, name: name, state: state}) do
    if function_exported?(mod, :source_stopped, 2),
      do: mod.source_stopped(name, state),
      else: :ok
  end

  # ---------------------------------------------------------------------------
  # Dispatch helpers — Pipeline (optional callbacks with defaults)
  # ---------------------------------------------------------------------------

  @doc "Validate statement safety via the adapter. Returns `:ok` without `Preflight`."
  @spec sanitize_query(t(), Statement.t(), keyword()) :: :ok | {:error, String.t()}
  def sanitize_query(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        opts
      ) do
    if has?(adapter, :preflight),
      do: mod.sanitize_query(state, statement, opts),
      else: :ok
  end

  @doc """
  Rewrite the statement after variable substitution, before filters and sorts
  are applied. Returns the statement unchanged if the adapter does not
  declare `Lotus.Source.Adapter.Binding`.
  """
  @spec transform_bound_query(t(), Statement.t(), keyword()) :: Statement.t()
  def transform_bound_query(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        opts
      ) do
    if has?(adapter, :binding),
      do: mod.transform_bound_query(state, statement, opts),
      else: statement
  end

  @doc """
  Extract accessed resources for preflight checks. Returns
  `{:unrestricted, reason}` if the adapter does not declare
  `Lotus.Source.Adapter.Preflight` —
  callers must consult the host-app `:allow_unrestricted_resources` opt-in
  before allowing the statement through.
  """
  @spec extract_accessed_resources(t(), Statement.t()) ::
          {:ok, MapSet.t({String.t() | nil, String.t()})}
          | {:error, term()}
          | {:unrestricted, String.t()}
  def extract_accessed_resources(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement
      ) do
    if has?(adapter, :preflight),
      do: mod.extract_accessed_resources(state, statement),
      else:
        {:unrestricted, "adapter #{inspect(mod)} does not declare Lotus.Source.Adapter.Preflight"}
  end

  @doc """
  Apply pagination to the statement. The paginated statement carries any
  count spec in `statement.meta[:count_spec]`. Returns the statement
  unchanged if the adapter does not declare `Lotus.Source.Adapter.Shaping`.
  """
  @spec apply_pagination(t(), Statement.t(), keyword()) :: Statement.t()
  def apply_pagination(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        opts
      ) do
    if has?(adapter, :shaping),
      do: mod.apply_pagination(state, statement, opts),
      else: statement
  end

  @doc """
  Whether the statement needs the visibility preflight check. Returns `true`
  if the adapter does not declare `Lotus.Source.Adapter.Preflight` — the
  safer default.
  """
  @spec needs_preflight?(t(), Statement.t()) :: boolean()
  def needs_preflight?(%__MODULE__{module: mod, state: state} = adapter, %Statement{} = statement) do
    if has?(adapter, :preflight),
      do: mod.needs_preflight?(state, statement),
      else: true
  end

  # ---------------------------------------------------------------------------
  # Dispatch helpers — SQL generation (pass adapter.state for correct dispatch)
  # ---------------------------------------------------------------------------

  @doc "Quote a SQL identifier via the adapter."
  @spec quote_identifier(t(), String.t()) :: String.t()
  def quote_identifier(%__MODULE__{module: mod, state: state} = adapter, identifier) do
    if has?(adapter, :shaping),
      do: mod.quote_identifier(state, identifier),
      else: identifier
  end

  @doc """
  Substitute a `{{var}}` scalar variable via the adapter. Returns
  `{:error, :unsupported}` when the adapter does not declare
  `Lotus.Source.Adapter.Binding`.
  """
  @spec substitute_variable(t(), Statement.t(), String.t(), term(), atom() | nil) ::
          {:ok, Statement.t()} | {:error, term()}
  def substitute_variable(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        var_name,
        value,
        type
      ) do
    if has?(adapter, :binding),
      do: mod.substitute_variable(state, statement, var_name, value, type),
      else: {:error, :unsupported}
  end

  @doc """
  Substitute a `{{var}}` list variable via the adapter. Returns
  `{:error, :unsupported}` when the adapter does not declare
  `Lotus.Source.Adapter.Binding`.
  """
  @spec substitute_list_variable(t(), Statement.t(), String.t(), [term()], atom() | nil) ::
          {:ok, Statement.t()} | {:error, term()}
  def substitute_list_variable(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        var_name,
        values,
        type
      )
      when is_list(values) do
    if has?(adapter, :binding),
      do: mod.substitute_list_variable(state, statement, var_name, values, type),
      else: {:error, :unsupported}
  end

  @doc """
  Validate a statement via the adapter. Returns `:ok` if the adapter does
  not declare `Lotus.Source.Adapter.Preflight` (trust-on-execute).
  """
  @spec validate_statement(t(), Statement.t(), keyword()) :: :ok | {:error, term()}
  def validate_statement(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        opts
      ) do
    if has?(adapter, :preflight),
      do: mod.validate_statement(state, statement, opts),
      else: :ok
  end

  @doc """
  Parse a qualified name into hierarchy components via the adapter.
  Returns `{:ok, [name]}` (single-component) if the adapter does not
  implement the callback.
  """
  @spec parse_qualified_name(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def parse_qualified_name(%__MODULE__{module: mod, state: state} = adapter, name)
      when is_binary(name) do
    if has?(adapter, :introspection),
      do: mod.parse_qualified_name(state, name),
      else: {:ok, [name]}
  end

  @doc """
  Validate an identifier for the given kind via the adapter. Returns `:ok`
  (permissive) if the adapter does not declare
  `Lotus.Source.Adapter.Introspection`.
  """
  @spec validate_identifier(t(), :schema | :table | :column, String.t()) ::
          :ok | {:error, String.t()}
  def validate_identifier(%__MODULE__{module: mod, state: state} = adapter, kind, value)
      when kind in [:schema, :table, :column] and is_binary(value) do
    if has?(adapter, :introspection),
      do: mod.validate_identifier(state, kind, value),
      else: :ok
  end

  @doc """
  Return the filter operators this adapter's `apply_filters/3` supports.
  Defaults to `Lotus.Query.Filter.operators/0` without its text operators
  (`Lotus.Query.Filter.text_operators/0`) if the adapter does not declare
  `Lotus.Source.Adapter.Shaping`.
  """
  @spec supported_filter_operators(t()) :: [atom()]
  def supported_filter_operators(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :shaping),
      do: mod.supported_filter_operators(state),
      else: Filter.operators() -- Filter.text_operators()
  end

  @doc "Apply filters to a statement via the adapter. Empty filters short-circuit."
  @spec apply_filters(t(), Statement.t(), list()) :: Statement.t()
  def apply_filters(_adapter, %Statement{} = statement, []), do: statement

  def apply_filters(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        filters
      ) do
    if has?(adapter, :shaping),
      do: mod.apply_filters(state, statement, filters),
      else: statement
  end

  @doc "Apply sorts to a statement via the adapter. Empty sorts short-circuit."
  @spec apply_sorts(t(), Statement.t(), list()) :: Statement.t()
  def apply_sorts(_adapter, %Statement{} = statement, []), do: statement

  def apply_sorts(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        sorts
      ) do
    if has?(adapter, :shaping),
      do: mod.apply_sorts(state, statement, sorts),
      else: statement
  end

  @doc "Format an error via the adapter."
  @spec format_error(t(), any()) :: String.t()
  def format_error(%__MODULE__{module: mod, state: state}, error) do
    mod.format_error(state, error)
  end

  @doc "Return the source type via the adapter."
  @spec source_type(t()) :: source_type()
  def source_type(%__MODULE__{module: mod, state: state}) do
    mod.source_type(state)
  end

  @doc "Check feature support via the adapter."
  @spec supports_feature?(t(), atom()) :: boolean()
  def supports_feature?(%__MODULE__{module: mod, state: state}, feature) do
    function_exported?(mod, :supports_feature?, 2) and mod.supports_feature?(state, feature)
  end

  @doc "Return the query language identifier via the adapter."
  @spec query_language(t()) :: String.t()
  def query_language(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :editor),
      do: mod.query_language(state),
      else: "sql"
  end

  @doc """
  Return the lexical profile the template layer tokenizes this adapter's
  statements with.

  The base profile comes from `query_language/1`, so a `"sql:mysql"` adapter
  gets backticks and `#` comments and a `"json:elasticsearch"` adapter gets
  JSON strings and no comments. The `:dialect_spec` of `editor_config/1`,
  when present, refines it, so the declaration that drives the editor's
  highlighter also drives server-side tokenization. An adapter with neither
  gets ANSI SQL.
  """
  @spec lexical_profile(t()) :: Profile.t()
  def lexical_profile(%__MODULE__{} = adapter) do
    base = Profile.for_language(query_language(adapter))
    spec = adapter |> editor_config() |> Map.get(:dialect_spec)
    Profile.from_dialect_spec(base, spec)
  end

  # Hard limits on the free-form AI context fields. Adapters that return
  # values over these bounds are truncated at this dispatch layer with a
  # one-time warning — prevents a noisy or compromised adapter from
  # bloating the prompt beyond the LLM's context budget.
  @ai_context_max_example_query_bytes 2048
  @ai_context_max_syntax_notes_bytes 1024
  @ai_context_max_generation_notes_bytes 1024
  @ai_context_max_read_only_notes_bytes 1024
  @ai_context_max_error_patterns 20

  # Constrains the `:language` field to a small character set so untrusted
  # adapters can't inject prompt text through it.
  @ai_context_language_regex ~r/\A[a-z0-9]+:[a-z0-9_-]+\z/

  @doc """
  Return the adapter's AI context, with free-form fields capped at safe
  sizes.

  Returns `{:error, :ai_not_supported}` if the adapter does not declare
  `Lotus.Source.Adapter.Editor` — the host can branch on this to disable AI features for
  the source.

  Oversized `:example_query`, `:syntax_notes`, or `:error_patterns` are
  truncated at the dispatch layer with a one-time `Logger.warning/1` per
  adapter module. A `:language` value that doesn't match the allowed
  character set (`^[a-z0-9]+:[a-z0-9_-]+$`) is replaced with `"unknown"`.
  """
  @spec ai_context(t()) :: {:ok, ai_context_map()} | {:error, term()}
  def ai_context(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :editor) do
      case mod.ai_context(state) do
        {:ok, ctx} when is_map(ctx) -> {:ok, sanitize_ai_context(mod, ctx)}
        {:error, _} = err -> err
        other -> {:error, {:invalid_ai_context, other}}
      end
    else
      {:error, :ai_not_supported}
    end
  end

  @doc """
  Prepare a statement for optimization analysis via the adapter. Returns
  `{:error, :unsupported}` if the adapter does not declare
  `Lotus.Source.Adapter.Preflight` — callers skip optimization for that adapter.
  """
  @spec prepare_for_analysis(t(), Statement.t()) :: {:ok, Statement.t()} | {:error, term()}
  def prepare_for_analysis(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement
      ) do
    if has?(adapter, :preflight),
      do: mod.prepare_for_analysis(state, statement),
      else: {:error, :unsupported}
  end

  # Trust boundary: untrusted adapters supply only `:language` to the
  # prompt. Free-form fields (`:example_query`, `:syntax_notes`,
  # `:error_patterns`) are discarded so a compromised or incidentally
  # adversarial adapter can't inject prompt text. Capability
  # declarations still apply — they gate feature visibility, not prompt
  # content — but their reason strings are replaced with a generic
  # fallback for untrusted adapters (same injection concern).
  defp sanitize_ai_context(mod, ctx) do
    ctx
    |> sanitize_language(mod)
    |> apply_trust_boundary(mod)
    |> truncate_bytes(
      :example_query,
      @ai_context_max_example_query_bytes,
      mod
    )
    |> truncate_bytes(
      :syntax_notes,
      @ai_context_max_syntax_notes_bytes,
      mod
    )
    |> truncate_bytes(
      :generation_notes,
      @ai_context_max_generation_notes_bytes,
      mod
    )
    |> truncate_bytes(
      :read_only_notes,
      @ai_context_max_read_only_notes_bytes,
      mod
    )
    |> truncate_list(:error_patterns, @ai_context_max_error_patterns, mod)
    |> normalize_capabilities(mod)
  end

  defp apply_trust_boundary(ctx, mod) do
    if Lotus.Config.trusted_source_adapter?(mod) do
      ctx
    else
      # Only signal when there was actually something to strip — adapters that
      # legitimately contribute just :language never trip this. The strip is an
      # intentional config consequence (adapter not allowlisted), not a
      # misconfiguration, so it logs at :info; the host's only other signal
      # would otherwise be downstream LLM-quality drift.
      if has_text_fields?(ctx) do
        warn_ai_context_once(
          mod,
          :trust_boundary,
          "stripped to language-only (not in :trusted_source_adapters); AI prompts " <>
            "will not see this adapter's syntax_notes / example_query / " <>
            "error_patterns / generation_notes / read_only_notes",
          :info
        )
      end

      # `:generation_notes` and `:read_only_notes` are dropped, not blanked.
      # The prompt layer falls back to core's own guidance on a missing key,
      # and an empty `:read_only_notes` would otherwise leave the prompt with
      # no read-only instruction at all — a way for an untrusted adapter to
      # weaken the guard by supplying a blank string.
      ctx
      |> Map.put(:example_query, "")
      |> Map.put(:syntax_notes, "")
      |> Map.put(:error_patterns, [])
      |> Map.delete(:generation_notes)
      |> Map.delete(:read_only_notes)
    end
  end

  defp has_text_fields?(ctx) do
    Map.get(ctx, :example_query) not in [nil, ""] or
      Map.get(ctx, :syntax_notes) not in [nil, ""] or
      Map.get(ctx, :error_patterns) not in [nil, []] or
      Map.get(ctx, :generation_notes) not in [nil, ""] or
      Map.get(ctx, :read_only_notes) not in [nil, ""]
  end

  # Default to all-supported when the adapter omits `:capabilities` —
  # existing adapters that returned `{:ok, ctx}` before this extension
  # should opt into everything. For untrusted adapters, any `{false,
  # reason}` has its reason replaced with a generic fallback.
  @generic_unsupported_reason "This feature is not available for this data source."

  defp normalize_capabilities(ctx, mod) do
    caps =
      ctx
      |> Map.get(:capabilities, %{})
      |> ensure_capability(:generation)
      |> ensure_capability(:optimization)
      |> ensure_capability(:explanation)
      |> filter_capability_reasons(mod)

    Map.put(ctx, :capabilities, caps)
  end

  defp ensure_capability(caps, key) do
    case Map.get(caps, key) do
      true -> caps
      {false, reason} when is_binary(reason) -> caps
      false -> Map.put(caps, key, {false, @generic_unsupported_reason})
      nil -> Map.put(caps, key, true)
      _ -> Map.put(caps, key, true)
    end
  end

  defp filter_capability_reasons(caps, mod) do
    if Lotus.Config.trusted_source_adapter?(mod) do
      caps
    else
      Enum.into(caps, %{}, fn
        {key, {false, _reason}} -> {key, {false, @generic_unsupported_reason}}
        {key, true} -> {key, true}
      end)
    end
  end

  defp sanitize_language(ctx, mod) do
    case Map.get(ctx, :language) do
      lang when is_binary(lang) ->
        if Regex.match?(@ai_context_language_regex, lang) do
          ctx
        else
          warn_ai_context_once(mod, :language, "invalid format")
          Map.put(ctx, :language, "unknown")
        end

      _ ->
        warn_ai_context_once(mod, :language, "missing or non-binary")
        Map.put(ctx, :language, "unknown")
    end
  end

  defp truncate_bytes(ctx, key, limit, mod) do
    case Map.get(ctx, key) do
      value when is_binary(value) and byte_size(value) > limit ->
        warn_ai_context_once(mod, key, "exceeds #{limit} bytes, truncating")
        Map.put(ctx, key, binary_part(value, 0, limit))

      _ ->
        ctx
    end
  end

  defp truncate_list(ctx, key, limit, mod) do
    case Map.get(ctx, key) do
      list when is_list(list) and length(list) > limit ->
        warn_ai_context_once(mod, key, "exceeds #{limit} entries, truncating")
        Map.put(ctx, key, Enum.take(list, limit))

      _ ->
        ctx
    end
  end

  # Emit each (adapter, field) notice once per BEAM node so a misconfigured or
  # un-allowlisted adapter doesn't spam the log on every AI call. `level`
  # defaults to :warning for cap/format violations; the trust-boundary strip
  # passes :info since it's an intentional config consequence.
  defp warn_ai_context_once(mod, field, msg, level \\ :warning) do
    key = {__MODULE__, :ai_context_warn, mod, field}

    case :persistent_term.get(key, :none) do
      :warned ->
        :ok

      :none ->
        :persistent_term.put(key, :warned)
        require Logger
        Logger.log(level, "ai_context from #{inspect(mod)} field #{inspect(field)}: #{msg}")
    end
  end

  # Caps on editor_config list sizes. A noisy or compromised adapter
  # could otherwise ship a huge payload that flows over LiveView to
  # every editor session. Enforced at the dispatch layer, same
  # philosophy as the ai_context caps above.
  @editor_config_max_keywords 2000
  @editor_config_max_types 2000
  @editor_config_max_functions 500
  @editor_config_max_context_schema_root 200
  @editor_config_max_context_schema_children 500

  # Editor shape for adapters that declare no editor support: the query
  # editor renders plain text with no completions rather than crashing.
  @empty_editor_config %{
    language: "",
    keywords: [],
    types: [],
    functions: [],
    context_boundaries: []
  }

  @editor_config_known_keys [
    :language,
    :keywords,
    :types,
    :functions,
    :context_boundaries,
    :dialect_spec,
    :context_schema
  ]

  @doc """
  Return editor configuration via the adapter, with list sizes capped
  at safe limits.

  Unknown top-level keys are dropped; oversized `:keywords`, `:types`,
  `:functions`, `:context_schema.root`, and `:context_schema.children`
  are truncated with a one-time `Logger.warning/1` per adapter module.
  Prevents a misbehaving adapter from bloating every editor session's
  LiveView payload.
  """
  @spec editor_config(t()) :: map()
  def editor_config(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :editor) do
      state |> mod.editor_config() |> sanitize_editor_config(mod)
    else
      @empty_editor_config
    end
  end

  defp sanitize_editor_config(config, mod) when is_map(config) do
    config
    |> Map.take(@editor_config_known_keys)
    |> truncate_list_field(:keywords, @editor_config_max_keywords, mod)
    |> truncate_list_field(:types, @editor_config_max_types, mod)
    |> truncate_list_field(:functions, @editor_config_max_functions, mod)
    |> truncate_context_schema(mod)
  end

  defp sanitize_editor_config(other, _mod), do: other

  defp truncate_list_field(config, key, limit, mod) do
    case Map.get(config, key) do
      list when is_list(list) and length(list) > limit ->
        warn_editor_config_once(mod, key, "exceeds #{limit} entries, truncating")
        Map.put(config, key, Enum.take(list, limit))

      _ ->
        config
    end
  end

  defp truncate_context_schema(config, mod) do
    case Map.get(config, :context_schema) do
      %{} = schema ->
        schema =
          schema
          |> truncate_schema_root(mod)
          |> truncate_schema_children(mod)

        Map.put(config, :context_schema, schema)

      _ ->
        config
    end
  end

  defp truncate_schema_root(schema, mod) do
    case Map.get(schema, :root) do
      list when is_list(list) and length(list) > @editor_config_max_context_schema_root ->
        warn_editor_config_once(
          mod,
          :context_schema_root,
          "exceeds #{@editor_config_max_context_schema_root} entries, truncating"
        )

        Map.put(schema, :root, Enum.take(list, @editor_config_max_context_schema_root))

      _ ->
        schema
    end
  end

  defp truncate_schema_children(schema, mod) do
    case Map.get(schema, :children) do
      %{} = children when map_size(children) > @editor_config_max_context_schema_children ->
        warn_editor_config_once(
          mod,
          :context_schema_children,
          "exceeds #{@editor_config_max_context_schema_children} entries, truncating"
        )

        truncated =
          children
          |> Enum.take(@editor_config_max_context_schema_children)
          |> Map.new()

        Map.put(schema, :children, truncated)

      _ ->
        schema
    end
  end

  defp warn_editor_config_once(mod, field, msg) do
    key = {__MODULE__, :editor_config_warn, mod, field}

    case :persistent_term.get(key, :none) do
      :warned ->
        :ok

      :none ->
        :persistent_term.put(key, :warned)
        require Logger
        Logger.warning("editor_config from #{inspect(mod)} field #{inspect(field)}: #{msg}")
    end
  end

  @doc "Wrap a statement with a limit clause via the adapter."
  @spec limit_query(t(), Statement.t(), pos_integer()) :: Statement.t()
  def limit_query(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement,
        limit
      ) do
    if has?(adapter, :shaping),
      do: mod.limit_query(state, statement, limit),
      else: statement
  end

  @doc "Return the hierarchy label via the adapter."
  @spec hierarchy_label(t()) :: String.t()
  def hierarchy_label(%__MODULE__{module: mod, state: state} = adapter) do
    if has?(adapter, :introspection),
      do: mod.hierarchy_label(state),
      else: "Tables"
  end

  @doc "Return an example query via the adapter."
  @spec example_query(t(), String.t(), String.t() | nil) :: String.t()
  def example_query(%__MODULE__{module: mod, state: state} = adapter, table, schema) do
    if has?(adapter, :editor),
      do: mod.example_query(state, table, schema),
      else: "SELECT value_column FROM #{table}"
  end

  @doc """
  Rewrite the statement before variable binding. Returns the statement
  unchanged if the adapter does not declare `Lotus.Source.Adapter.Binding`.
  """
  @spec transform_statement(t(), Statement.t()) :: Statement.t()
  def transform_statement(
        %__MODULE__{module: mod, state: state} = adapter,
        %Statement{} = statement
      ) do
    if has?(adapter, :binding),
      do: mod.transform_statement(state, statement),
      else: statement
  end

  @doc "Map a database type to a Lotus type via the adapter."
  @spec db_type_to_lotus_type(t(), String.t()) :: atom()
  def db_type_to_lotus_type(%__MODULE__{module: mod, state: state} = adapter, db_type) do
    if has?(adapter, :binding),
      do: mod.db_type_to_lotus_type(state, db_type),
      else: :text
  end
end
