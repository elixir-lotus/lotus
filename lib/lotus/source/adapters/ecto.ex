defmodule Lotus.Source.Adapters.Ecto do
  @moduledoc """
  Adapter wrapping any `Ecto.Repo` module in the `Lotus.Source.Adapter` behaviour.

  Delegates database-specific operations to dialect modules under
  `Lotus.Source.Adapters.Ecto.Dialects.*` based on the repo's underlying
  Ecto adapter.

  ## Usage

      adapter = Lotus.Source.Adapters.Ecto.wrap("main", MyApp.Repo)

      Lotus.Source.Adapter.execute_query(adapter, "SELECT 1", [], [])
      Lotus.Source.Adapter.list_schemas(adapter)

  The `state` field of the resulting `%Adapter{}` struct holds the repo module
  itself, since Ecto repos are statically supervised and don't require explicit
  connection management.

  ## Dynamic repos

  A repo started at runtime without a name (`MyApp.Repo.start_link(name: nil)`)
  is reachable only through `c:Ecto.Repo.put_dynamic_repo/1`, which applies to
  the calling process. Pass the state as a map to have the adapter make that
  call around every repo operation:

      adapter =
        Lotus.Source.Adapters.Ecto.wrap("tenant", %{repo: MyApp.Repo, dynamic: pid})

  `:repo` is the repo module the process was started from. `:dynamic` is
  what `put_dynamic_repo/1` takes, a pid or an atom, or a `{:via, _, _}` or
  `{:global, _}` name that the adapter resolves to a pid on every call, so a
  repo started under `Lotus.Source.Registry.via/2` can be wrapped before it
  is running. The previous dynamic repo of the calling process is restored
  after each call. `with_repo/2` is the helper the callbacks use and is
  available to adapters that override one of them.

  ## Extending with custom Ecto-backed adapters

  External libraries can create Ecto-backed adapters by writing a dialect
  module and a one-liner adapter:

      defmodule LotusMSSql.Adapter do
        use Lotus.Source.Adapters.Ecto, dialect: LotusMSSql.Dialect
      end

  The `use` macro declares `Lotus.Source.Adapter` and the capability
  behaviours `Lotus.Source.Adapter.Introspection`, `Preflight`, `Binding`,
  `Shaping` and `Editor`, and injects default implementations for all their
  callbacks, delegating shared Ecto logic to helper
  functions in this module and dialect-specific callbacks to the provided
  `:dialect` module. All callbacks are `defoverridable`.
  """

  @behaviour Lotus.Source.Adapter
  @behaviour Lotus.Source.Adapter.Introspection
  @behaviour Lotus.Source.Adapter.Preflight
  @behaviour Lotus.Source.Adapter.Binding
  @behaviour Lotus.Source.Adapter.Shaping
  @behaviour Lotus.Source.Adapter.Editor

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Lotus.Query.Filter
  alias Lotus.Query.OptionalClause
  alias Lotus.Query.Statement
  alias Lotus.Query.Tokenizer
  alias Lotus.Query.Tokenizer.Profile
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto.Dialects
  alias Lotus.SQL.Identifier
  alias Lotus.SQL.Sanitizer
  alias Lotus.Variables

  @default_dialect Dialects.Default

  @typedoc """
  Where a dynamic repo runs: what `c:Ecto.Repo.put_dynamic_repo/1` takes, or
  a process name that `GenServer.whereis/1` resolves on every call.
  """
  @type dynamic_target :: pid() | atom() | {:global, term()} | {:via, module(), term()}

  @typedoc "A repo module started at runtime, reached through `put_dynamic_repo/1`."
  @type dynamic_state :: %{
          :repo => module(),
          :dynamic => dynamic_target(),
          optional(atom()) => term()
        }

  @typedoc "The adapter state: a statically supervised repo module or a dynamic repo."
  @type state :: module() | dynamic_state()

  # ---------------------------------------------------------------------------
  # __using__ macro for external Ecto-backed adapters
  # ---------------------------------------------------------------------------

  defmacro __using__(opts) do
    dialect_ast =
      case Keyword.fetch(opts, :dialect) do
        {:ok, ast} ->
          ast

        :error ->
          raise ArgumentError,
                "use Lotus.Source.Adapters.Ecto requires a :dialect module — " <>
                  "e.g. `use Lotus.Source.Adapters.Ecto, dialect: MyDialect`"
      end

    # Resolve the alias AST to a module atom. Safe to do here because the
    # value has to be a literal module name, not an expression.
    dialect = Macro.expand(dialect_ast, __CALLER__)

    unless is_atom(dialect) do
      raise ArgumentError,
            "use Lotus.Source.Adapters.Ecto expects :dialect to be a module, got: " <>
              Macro.to_string(dialect_ast)
    end

    # Compile-time sanity check on the :dialect module. Uses the soft
    # `ensure_compiled` (not the bang variant) because the dialect and the
    # adapter that `use`s it are often compiled together — requiring the
    # dialect to be fully compiled here would deadlock the dep graph. When
    # the dialect IS already compiled, assert it implements the Dialect
    # behaviour so typo'd modules that happen to be loaded still raise.
    case Code.ensure_compiled(dialect) do
      {:module, ^dialect} ->
        behaviours =
          dialect.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        unless Lotus.Source.Adapters.Ecto.Dialect in behaviours do
          raise ArgumentError,
                "#{inspect(dialect)} does not implement the " <>
                  "Lotus.Source.Adapters.Ecto.Dialect behaviour. Add " <>
                  "`@behaviour Lotus.Source.Adapters.Ecto.Dialect` to the dialect module."
        end

      {:error, _reason} ->
        # Dialect isn't compiled yet (co-compile cycle). Skip the behaviour
        # assertion here — Elixir's usual compile-time @behaviour warnings
        # will catch mismatches when the dialect does compile.
        :ok
    end

    connection_ast = Keyword.get(opts, :connection)

    quote do
      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Introspection
      @behaviour Lotus.Source.Adapter.Preflight
      @behaviour Lotus.Source.Adapter.Binding
      @behaviour Lotus.Source.Adapter.Shaping
      @behaviour Lotus.Source.Adapter.Editor

      @dialect unquote(dialect)

      alias Lotus.Source.Adapter
      alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

      unquote(registration_callbacks())
      unquote(execution_callbacks())
      unquote(introspection_callbacks())
      unquote(sql_generation_callbacks())
      unquote(visibility_callbacks())
      unquote(lifecycle_callbacks())
      unquote(pipeline_callbacks())
      unquote(validation_callbacks())
      unquote(identity_callbacks())
      unquote(presentation_callbacks())
      unquote(type_mapping_callbacks())
      unquote(if connection_ast, do: connection_callbacks(connection_ast))

      defoverridable Lotus.Source.Adapter
      defoverridable Lotus.Source.Adapter.Introspection
      defoverridable Lotus.Source.Adapter.Preflight
      defoverridable Lotus.Source.Adapter.Binding
      defoverridable Lotus.Source.Adapter.Shaping
      defoverridable Lotus.Source.Adapter.Editor
    end
  end

  defp registration_callbacks do
    quote do
      @impl true
      def can_handle?(repo) when is_atom(repo) do
        Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and
          repo.__adapter__() == @dialect.ecto_adapter()
      end

      def can_handle?(%{repo: repo, dynamic: _}), do: can_handle?(repo)

      def can_handle?(_), do: false

      @impl true
      def wrap(name, state) when is_binary(name) do
        Adapter.with_capabilities(%Adapter{
          name: name,
          module: __MODULE__,
          state: EctoAdapter.validate_state!(state),
          source_type: @dialect.source_type()
        })
      end
    end
  end

  defp execution_callbacks do
    quote do
      @impl true
      def execute_query(state, sql, params, opts) do
        EctoAdapter.with_repo(state, fn repo ->
          EctoAdapter.do_execute_query(@dialect, repo, sql, params, opts)
        end)
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def transaction(state, fun, opts) do
        EctoAdapter.with_repo(state, fn repo ->
          @dialect.execute_in_transaction(repo, fn -> fun.(repo) end, opts)
        end)
      end
    end
  end

  defp introspection_callbacks do
    quote do
      @impl true
      def list_schemas(state) do
        {:ok, EctoAdapter.with_repo(state, fn repo -> @dialect.list_schemas(repo) end)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def list_tables(state, schemas, opts) do
        include_views? = Keyword.get(opts, :include_views, false)

        {:ok,
         EctoAdapter.with_repo(state, fn repo ->
           @dialect.list_tables(repo, schemas, include_views?)
         end)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def describe_table(state, schema, table) do
        {:ok,
         EctoAdapter.with_repo(state, fn repo -> @dialect.describe_table(repo, schema, table) end)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def resolve_table_namespace(state, table, schemas) do
        {:ok,
         EctoAdapter.with_repo(state, fn repo ->
           @dialect.resolve_table_namespace(repo, table, schemas)
         end)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def table_row_estimates(state, schemas) do
        if Code.ensure_loaded?(@dialect) and function_exported?(@dialect, :table_row_estimates, 2) do
          {:ok,
           EctoAdapter.with_repo(state, fn repo ->
             @dialect.table_row_estimates(repo, schemas)
           end)}
        else
          {:error, :unsupported}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end
    end
  end

  defp sql_generation_callbacks do
    quote do
      @impl true
      def quote_identifier(_repo, identifier), do: @dialect.quote_identifier(identifier)

      @impl true
      def apply_filters(_repo, statement, filters),
        do: @dialect.apply_filters(statement, filters)

      @impl true
      def apply_sorts(_repo, statement, sorts), do: @dialect.apply_sorts(statement, sorts)

      @impl true
      def query_plan(state, statement, opts) do
        EctoAdapter.with_repo(state, fn repo -> @dialect.query_plan(repo, statement, opts) end)
      end
    end
  end

  defp visibility_callbacks do
    quote do
      @impl true
      def builtin_denies(state),
        do: EctoAdapter.with_repo(state, fn repo -> @dialect.builtin_denies(repo) end)

      @impl true
      def builtin_schema_denies(state),
        do: EctoAdapter.with_repo(state, fn repo -> @dialect.builtin_schema_denies(repo) end)

      @impl true
      def default_schemas(state),
        do: EctoAdapter.with_repo(state, fn repo -> @dialect.default_schemas(repo) end)
    end
  end

  defp lifecycle_callbacks do
    quote do
      @impl true
      def health_check(state), do: EctoAdapter.do_health(state)

      @impl true
      def disconnect(_repo), do: :ok

      @impl true
      def format_error(_repo, error), do: @dialect.format_error(error)
    end
  end

  # The `:connection` option: a repo module to start sources from, and the
  # callbacks of `Lotus.Source.Adapter.Connection` over it.
  defp connection_callbacks(connection_ast) do
    quote do
      @behaviour Lotus.Source.Adapter.Connection

      @connection_repo EctoAdapter.__define_repo__(__MODULE__, @dialect.ecto_adapter(), __ENV__)
      @connection_test Keyword.get(unquote(connection_ast), :test, :connect)

      # Decided as the module compiles: whether the Ecto adapter is there.
      if @connection_repo do
        @impl Lotus.Source.Adapter.Connection
        def connection,
          do: unquote(connection_ast) |> Keyword.take([:kind, :label, :fields]) |> Map.new()

        @impl Lotus.Source.Adapter.Connection
        def from_settings(name, settings) do
          EctoAdapter.settings_state(
            __MODULE__,
            @connection_repo,
            name,
            settings,
            @connection_test
          )
        end
      else
        @impl Lotus.Source.Adapter.Connection
        def connection, do: nil

        @impl Lotus.Source.Adapter.Connection
        def from_settings(_name, _settings),
          do: {:error, "The database library this kind of source needs is not installed."}
      end

      @impl Lotus.Source.Adapter
      def source_children(_name, state), do: EctoAdapter.settings_children(state)

      defoverridable Lotus.Source.Adapter.Connection
    end
  end

  defp pipeline_callbacks do
    quote do
      @impl true
      def sanitize_query(_repo, statement, opts),
        do: EctoAdapter.do_sanitize_query(@dialect, statement, opts)

      @impl true
      def transform_bound_query(_repo, statement, _opts), do: statement

      @impl true
      def extract_accessed_resources(state, statement) do
        EctoAdapter.with_repo(state, fn repo ->
          EctoAdapter.do_extract_accessed_resources(@dialect, repo, statement)
        end)
      end

      @impl true
      def apply_pagination(state, statement, pagination_opts) do
        EctoAdapter.with_repo(state, fn repo ->
          EctoAdapter.do_apply_pagination(@dialect, repo, statement, pagination_opts)
        end)
      end

      @impl true
      def needs_preflight?(_repo, statement),
        do: EctoAdapter.do_needs_preflight?(@dialect, statement)

      @impl true
      def substitute_variable(_repo, statement, var_name, value, type),
        do: EctoAdapter.do_substitute_variable(@dialect, statement, var_name, value, type)

      @impl true
      def substitute_list_variable(_repo, statement, var_name, values, type),
        do: EctoAdapter.do_substitute_list_variable(@dialect, statement, var_name, values, type)
    end
  end

  defp validation_callbacks do
    quote do
      @impl true
      def validate_statement(state, statement, opts) do
        EctoAdapter.with_repo(state, fn repo ->
          EctoAdapter.do_validate_statement(@dialect, repo, statement, opts)
        end)
      end

      @impl true
      def parse_qualified_name(_repo, name), do: EctoAdapter.do_parse_qualified_name(name)

      @impl true
      def validate_identifier(_repo, kind, value),
        do: EctoAdapter.do_validate_identifier(kind, value)

      @impl true
      def supported_filter_operators(_repo),
        do: EctoAdapter.do_supported_filter_operators(@dialect)

      @impl true
      def ai_context(_repo), do: EctoAdapter.do_ai_context(@dialect)

      @impl true
      def prepare_for_analysis(_repo, statement),
        do: EctoAdapter.do_prepare_for_analysis(@dialect, statement)
    end
  end

  defp identity_callbacks do
    quote do
      @impl true
      def source_type(_repo), do: @dialect.source_type()

      @impl true
      def supports_feature?(_repo, feature) do
        if function_exported?(@dialect, :supports_feature?, 1),
          do: @dialect.supports_feature?(feature),
          else: false
      end

      @impl true
      def query_language(_repo), do: @dialect.query_language()

      @impl true
      def limit_query(_repo, statement, limit), do: @dialect.limit_query(statement, limit)

      @impl true
      def editor_config(_repo) do
        if function_exported?(@dialect, :editor_config, 0),
          do: @dialect.editor_config(),
          else: %{language: "sql", keywords: [], types: [], functions: [], context_boundaries: []}
      end
    end
  end

  defp presentation_callbacks do
    quote do
      @impl true
      def hierarchy_label(_repo) do
        if function_exported?(@dialect, :hierarchy_label, 0),
          do: @dialect.hierarchy_label(),
          else: "Tables"
      end

      @impl true
      def example_query(_repo, table, schema) do
        if function_exported?(@dialect, :example_query, 2),
          do: @dialect.example_query(table, schema),
          else: "SELECT value_column FROM #{table}"
      end
    end
  end

  defp type_mapping_callbacks do
    quote do
      @impl true
      def transform_statement(_repo, statement) do
        if function_exported?(@dialect, :transform_statement, 1),
          do: @dialect.transform_statement(statement),
          else: statement
      end

      @impl true
      def db_type_to_lotus_type(_repo, db_type) do
        if function_exported?(@dialect, :db_type_to_lotus_type, 1),
          do: @dialect.db_type_to_lotus_type(db_type),
          else: :text
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @builtin_ecto_adapters [
    Lotus.Source.Adapters.Postgres,
    Lotus.Source.Adapters.MySQL,
    Lotus.Source.Adapters.SQLite3
  ]

  @doc """
  Returns the list of built-in per-dialect Ecto adapter modules.

  Used by `Lotus.Source.Resolvers.Static` to avoid duplicating this list.
  """
  def builtin_adapters, do: @builtin_ecto_adapters

  @settings_pool_size 5

  @doc """
  Wraps an `Ecto.Repo` module in an `%Adapter{}` struct.

  The resulting adapter delegates all callbacks to the appropriate source
  implementation based on the repo's underlying Ecto adapter.

  ## Parameters

    * `name` — a human-readable identifier (e.g. `"main"`, `"warehouse"`)
    * `state` — the Ecto.Repo module (e.g. `MyApp.Repo`), or
      `%{repo: MyApp.Repo, dynamic: pid_or_name}` for a repo started at
      runtime (see the "Dynamic repos" section)

  ## Examples

      iex> adapter = Lotus.Source.Adapters.Ecto.wrap("main", MyApp.Repo)
      %Lotus.Source.Adapter{name: "main", module: Lotus.Source.Adapters.Ecto, ...}

      iex> Lotus.Source.Adapters.Ecto.wrap("tenant", %{repo: MyApp.Repo, dynamic: pid})
      %Lotus.Source.Adapter{name: "tenant", state: %{repo: MyApp.Repo, dynamic: pid}, ...}
  """
  @impl true
  @spec wrap(String.t(), state()) :: Adapter.t()
  def wrap(name, state) when is_binary(name) do
    state = validate_state!(state)
    repo_module = repo_module(state)

    case Enum.find(@builtin_ecto_adapters, & &1.can_handle?(repo_module)) do
      nil ->
        # Guard the fallback path: `can_handle?/1` is broad (any atom), so
        # without this check we'd happily wrap a non-Ecto atom like :typoed_name
        # and fail later with an opaque error during query execution.
        unless Code.ensure_loaded?(repo_module) and
                 function_exported?(repo_module, :__adapter__, 0) do
          raise ArgumentError,
                "Cannot wrap #{inspect(repo_module)} as an Ecto source — " <>
                  "the module does not export __adapter__/0. Either register " <>
                  "a custom `source_adapters` entry whose can_handle?/1 matches " <>
                  "this source, or pass an `Ecto.Repo` module."
        end

        Adapter.with_capabilities(%Adapter{
          name: name,
          module: __MODULE__,
          state: state,
          source_type: @default_dialect.source_type()
        })

      adapter_mod ->
        adapter_mod.wrap(name, state)
    end
  end

  @doc """
  Whether this adapter can handle the given data source entry.

  Returns `true` for any module that exports `__adapter__/0`, and for the
  `%{repo: module, dynamic: _}` form when its `:repo` does. This is
  intentionally broad — it acts as a catch-all fallback for Ecto repos
  that don't match a more specific per-dialect adapter. The resolver
  checks per-dialect adapters first (via `builtin_adapters/0` and
  `source_adapters` config), so this only matches repos with unknown
  Ecto adapters.
  """
  @impl true
  @spec can_handle?(term()) :: boolean()
  def can_handle?(repo) when is_atom(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0)
  end

  def can_handle?(%{repo: repo, dynamic: _}), do: can_handle?(repo)

  def can_handle?(_), do: false

  @doc """
  Runs `fun` with the repo module of `state`, routed to the dynamic repo
  when `state` carries one.

  For a repo module the function is called with the module as is. For a
  `%{repo: module, dynamic: target}` state, the target is resolved to a pid
  or an atom, `c:Ecto.Repo.put_dynamic_repo/1` is called on the repo module,
  `fun` runs, and the dynamic repo the calling process had before is put
  back, whether `fun` returns or raises. A `{:via, _, _}` or `{:global, _}`
  target whose process is not running raises `ArgumentError`.

  ## Examples

      Lotus.Source.Adapters.Ecto.with_repo(MyApp.Repo, & &1.query!("SELECT 1"))

      Lotus.Source.Adapters.Ecto.with_repo(%{repo: MyApp.Repo, dynamic: pid}, fn repo ->
        repo.query!("SELECT 1")
      end)
  """
  @spec with_repo(state(), (module() -> result)) :: result when result: term()
  def with_repo(%{repo: repo, dynamic: target}, fun) when is_atom(repo) and is_function(fun, 1) do
    previous = repo.put_dynamic_repo(resolve_dynamic_target!(target))

    try do
      fun.(repo)
    after
      repo.put_dynamic_repo(previous)
    end
  end

  def with_repo(repo, fun) when is_atom(repo) and is_function(fun, 1), do: fun.(repo)

  @doc """
  Returns the repo module of an adapter state, for either shape.
  """
  @spec repo_module(state()) :: module()
  def repo_module(%{repo: repo, dynamic: _}) when is_atom(repo), do: repo
  def repo_module(repo) when is_atom(repo), do: repo

  @doc false
  @spec validate_state!(term()) :: state()
  def validate_state!(repo) when is_atom(repo), do: repo

  def validate_state!(%{repo: repo, dynamic: target} = state)
      when is_atom(repo) and (is_pid(target) or is_atom(target) or is_tuple(target)),
      do: state

  def validate_state!(other) do
    raise ArgumentError,
          "an Ecto source expects an Ecto.Repo module or " <>
            "%{repo: module, dynamic: pid | name}, got: #{inspect(other)}"
  end

  defp resolve_dynamic_target!(target) when is_pid(target) or is_atom(target), do: target

  defp resolve_dynamic_target!(target) when is_tuple(target) do
    GenServer.whereis(target) ||
      raise ArgumentError, "dynamic repo #{inspect(target)} is not running"
  end

  @doc """
  Detects the source type from a repo module's underlying Ecto adapter.

  ## Examples

      iex> Lotus.Source.Adapters.Ecto.detect_source_type(MyApp.Repo)
      :postgres
  """
  @spec detect_source_type(module()) :: Adapter.source_type()
  def detect_source_type(repo_module) when is_atom(repo_module) do
    case repo_module.__adapter__() do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
      Ecto.Adapters.MyXQL -> :mysql
      _ -> :other
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Query Execution
  # ---------------------------------------------------------------------------

  @impl true
  def execute_query(state, sql, params, opts) do
    with_repo(state, &do_execute_query(@default_dialect, &1, sql, params, opts))
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def transaction(state, fun, opts) do
    with_repo(state, fn repo ->
      @default_dialect.execute_in_transaction(repo, fn -> fun.(repo) end, opts)
    end)
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Introspection (wrap bare returns in {:ok, _} tuples)
  # ---------------------------------------------------------------------------

  @impl true
  def list_schemas(state) do
    {:ok, with_repo(state, &@default_dialect.list_schemas/1)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def list_tables(state, schemas, opts) do
    include_views? = Keyword.get(opts, :include_views, false)
    {:ok, with_repo(state, &@default_dialect.list_tables(&1, schemas, include_views?))}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def describe_table(state, schema, table) do
    {:ok, with_repo(state, &@default_dialect.describe_table(&1, schema, table))}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def resolve_table_namespace(state, table, schemas) do
    {:ok, with_repo(state, &@default_dialect.resolve_table_namespace(&1, table, schemas))}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Callbacks — SQL Generation (delegate to source impl via state)
  # ---------------------------------------------------------------------------

  @impl true
  def quote_identifier(_repo, identifier) do
    @default_dialect.quote_identifier(identifier)
  end

  @impl true
  def apply_filters(_repo, statement, filters) do
    @default_dialect.apply_filters(statement, filters)
  end

  @impl true
  def apply_sorts(_repo, statement, sorts) do
    @default_dialect.apply_sorts(statement, sorts)
  end

  @impl true
  def query_plan(state, statement, opts) do
    with_repo(state, &@default_dialect.query_plan(&1, statement, opts))
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Safety & Visibility (delegate to source impl)
  # ---------------------------------------------------------------------------

  @impl true
  def builtin_denies(state) do
    with_repo(state, &@default_dialect.builtin_denies/1)
  end

  @impl true
  def builtin_schema_denies(state) do
    with_repo(state, &@default_dialect.builtin_schema_denies/1)
  end

  @impl true
  def default_schemas(state) do
    with_repo(state, &@default_dialect.default_schemas/1)
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def health_check(state), do: do_health(state)

  @impl true
  def disconnect(_repo) do
    # Static repos are managed by the application supervisor.
    :ok
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Error Handling
  # ---------------------------------------------------------------------------

  @impl true
  def format_error(_repo, error) do
    @default_dialect.format_error(error)
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Pipeline (Query Processing)
  # ---------------------------------------------------------------------------

  # Deny list for dangerous operations (defense-in-depth).
  # Skipped when `read_only: false` is passed in opts.
  @deny ~r/\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE|VACUUM|ANALYZE|ANALYSE|CALL|LOCK|OUTFILE|DUMPFILE)\b/i

  @impl true
  def sanitize_query(_repo, statement, opts),
    do: do_sanitize_query(@default_dialect, statement, opts)

  @impl true
  def transform_bound_query(_repo, statement, _opts), do: statement

  @impl true
  def extract_accessed_resources(state, statement) do
    with_repo(state, &do_extract_accessed_resources(@default_dialect, &1, statement))
  end

  @impl true
  def apply_pagination(state, statement, pagination_opts) do
    with_repo(state, &do_apply_pagination(@default_dialect, &1, statement, pagination_opts))
  end

  @impl true
  def needs_preflight?(_repo, statement),
    do: do_needs_preflight?(@default_dialect, statement)

  @impl true
  def substitute_variable(_repo, statement, var_name, value, type),
    do: do_substitute_variable(@default_dialect, statement, var_name, value, type)

  @impl true
  def substitute_list_variable(_repo, statement, var_name, values, type),
    do: do_substitute_list_variable(@default_dialect, statement, var_name, values, type)

  @impl true
  def validate_statement(state, statement, opts),
    do: with_repo(state, &do_validate_statement(@default_dialect, &1, statement, opts))

  @impl true
  def parse_qualified_name(_repo, name), do: do_parse_qualified_name(name)

  @impl true
  def validate_identifier(_repo, kind, value), do: do_validate_identifier(kind, value)

  @impl true
  def supported_filter_operators(_repo), do: do_supported_filter_operators(@default_dialect)

  @impl true
  def ai_context(_repo), do: do_ai_context(@default_dialect)

  @impl true
  def prepare_for_analysis(_repo, statement),
    do: do_prepare_for_analysis(@default_dialect, statement)

  # ---------------------------------------------------------------------------
  # Callbacks — Source Identity
  # ---------------------------------------------------------------------------

  @impl true
  def source_type(_repo), do: @default_dialect.source_type()

  @impl true
  def supports_feature?(_repo, feature) do
    if function_exported?(@default_dialect, :supports_feature?, 1),
      do: @default_dialect.supports_feature?(feature),
      else: false
  end

  @impl true
  def query_language(_repo), do: @default_dialect.query_language()

  @impl true
  def limit_query(_repo, statement, limit), do: @default_dialect.limit_query(statement, limit)

  @impl true
  def editor_config(_repo) do
    if function_exported?(@default_dialect, :editor_config, 0),
      do: @default_dialect.editor_config(),
      else: %{language: "sql", keywords: [], types: [], functions: [], context_boundaries: []}
  end

  @impl true
  def hierarchy_label(_repo) do
    if function_exported?(@default_dialect, :hierarchy_label, 0),
      do: @default_dialect.hierarchy_label(),
      else: "Tables"
  end

  @impl true
  def example_query(_repo, table, schema) do
    if function_exported?(@default_dialect, :example_query, 2),
      do: @default_dialect.example_query(table, schema),
      else: "SELECT value_column FROM #{table}"
  end

  @impl true
  def transform_statement(_repo, statement), do: statement

  @impl true
  def db_type_to_lotus_type(_repo, db_type), do: @default_dialect.db_type_to_lotus_type(db_type)

  # ---------------------------------------------------------------------------
  # Shared helpers (called by __using__ macro and this module's own callbacks)
  # ---------------------------------------------------------------------------

  @doc false
  def do_execute_query(dialect, repo, sql, params, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    search_path = Keyword.get(opts, :search_path)

    dialect.execute_in_transaction(
      repo,
      fn ->
        if search_path && function_exported?(dialect, :set_search_path, 2) do
          dialect.set_search_path(repo, search_path)
        end

        case repo.query(sql, params, timeout: timeout) do
          {:ok, %{columns: cols, rows: rows} = raw} ->
            num_rows = Map.get(raw, :num_rows, length(rows || []))

            %{columns: cols, rows: rows, num_rows: num_rows}
            |> maybe_put(:command, Map.get(raw, :command))
            |> maybe_put(:connection_id, Map.get(raw, :connection_id))
            |> maybe_put(:messages, Map.get(raw, :messages))

          {:error, err} ->
            repo.rollback(dialect.format_error(err))
        end
      end,
      opts
    )
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  # `c:Lotus.Source.Adapter.Streaming.stream_query/4` for the built-in Ecto
  # adapters. Built from the repo the process runs on, so a dynamic repo's
  # stream reads from it; enumerated inside the statement's transaction.
  def do_stream_query(state, sql, params, opts) do
    stream_opts = [
      max_rows: Keyword.get(opts, :max_rows, 500),
      timeout: Keyword.get(opts, :timeout, 15_000)
    ]

    with_repo(state, fn repo ->
      stream =
        repo.get_dynamic_repo()
        |> EctoSQL.stream(sql, params, stream_opts)
        |> Stream.map(fn raw -> %{columns: raw.columns || [], rows: raw.rows || []} end)

      {:ok, stream}
    end)
  end

  @doc false
  # A source connected from settings whose repo is not running, as when a
  # form tests it before it is saved, gets a connection of its own: through
  # the repo's pool, a failure would read "connection not available".
  def do_health(%{repo: repo, dynamic: target, config: config} = state) do
    cond do
      running?(target) ->
        with_repo(state, &do_health_check/1)

      state[:test] == :query ->
        with :ok <- probe(repo, config), do: probe_through_repo(repo, config)

      true ->
        probe(repo, config)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def do_health(state) do
    with_repo(state, &do_health_check/1)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp running?(target) when is_pid(target), do: Process.alive?(target)
  defp running?(target), do: GenServer.whereis(target) != nil

  @probe_timeout 10_000

  # One connection through the driver's DBConnection module, as the pool
  # would open it, then closed.
  defp probe(repo, config) do
    config = Keyword.merge(config, pool_size: 1, timeout: @probe_timeout)

    case driver(repo, config) do
      {:ok, driver, opts} ->
        # A driver traps exits in the process that connects.
        task = Task.async(fn -> connect_once(driver, opts) end)

        case Task.yield(task, @probe_timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _timeout -> {:error, "The database did not answer within 10 seconds."}
        end

      :error ->
        probe_through_repo(repo, config)
    end
  end

  defp driver(repo, config) do
    connection = Module.concat(repo.__adapter__(), Connection)

    with true <- Code.ensure_loaded?(connection),
         true <- function_exported?(connection, :child_spec, 1),
         %{start: {_pool, _fun, [{driver, opts}]}} when is_atom(driver) <-
           connection.child_spec(config),
         true <- Code.ensure_loaded?(driver),
         true <- function_exported?(driver, :connect, 1) do
      {:ok, driver, opts}
    else
      _other -> :error
    end
  end

  defp connect_once(driver, opts) do
    case driver.connect(opts) do
      {:ok, conn} ->
        driver.disconnect(:normal, conn)
        :ok

      {:error, error} ->
        {:error, error}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # A driver whose child spec is not a DBConnection pool's: start the repo
  # for one query.
  defp probe_through_repo(repo, config) do
    case repo.start_link(Keyword.put(config, :name, nil)) do
      {:ok, pid} ->
        try do
          with_repo(%{repo: repo, dynamic: pid}, &do_health_check/1)
        after
          Supervisor.stop(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Defines `<adapter>.Repo`, the repo module sources connected from
  # settings start from, when the Ecto adapter is installed. Returns it, or
  # `nil`.
  @spec __define_repo__(module(), module(), Macro.Env.t()) :: module() | nil
  def __define_repo__(adapter_module, ecto_adapter, env) do
    repo = Module.concat(adapter_module, Repo)

    if Code.ensure_loaded?(ecto_adapter) do
      contents =
        quote do
          @moduledoc false
          use Ecto.Repo, otp_app: :lotus, adapter: unquote(ecto_adapter)
        end

      Module.create(repo, contents, Macro.Env.location(env))
      repo
    end
  end

  @doc false
  # The state of a source connected from settings: its repo runs under
  # `Lotus.Source.Supervisor`, registered under the source's name.
  @spec settings_state(module(), module(), String.t(), keyword(), :connect | :query) ::
          {:ok, dynamic_state()}
  def settings_state(adapter_module, repo, name, settings, test \\ :connect) do
    state = %{
      repo: repo,
      dynamic: Lotus.Source.Registry.via(adapter_module, name),
      config: Keyword.put_new(settings, :pool_size, @settings_pool_size)
    }

    {:ok, if(test == :query, do: Map.put(state, :test, :query), else: state)}
  end

  @doc false
  # The repo of a source connected from settings; none for a repo the host
  # supervises.
  @spec settings_children(state()) :: [Supervisor.child_spec()]
  def settings_children(%{repo: repo, dynamic: name, config: config}) do
    [
      %{
        id: repo,
        start: {repo, :start_link, [Keyword.put(config, :name, name)]},
        type: :supervisor
      }
    ]
  end

  def settings_children(_state), do: []

  @doc """
  The fields of a form that connects a database server: host, port,
  database, user, password and SSL, for the `:connection` option of
  `use Lotus.Source.Adapters.Ecto`.
  """
  @spec server_fields(pos_integer()) :: [Lotus.Source.Adapter.Connection.field()]
  def server_fields(default_port) do
    [
      %{key: :hostname, label: "Host", type: :string, required: true, placeholder: "db.internal"},
      %{key: :port, label: "Port", type: :integer, default: default_port},
      %{key: :database, label: "Database", type: :string, required: true},
      %{key: :username, label: "User", type: :string, required: true},
      %{key: :password, label: "Password", type: :secret},
      %{key: :ssl, label: "Use SSL", type: :boolean, default: false}
    ]
  end

  @doc false
  def do_health_check(repo) do
    case repo.query("SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, err} -> {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  def do_sanitize_query(dialect, %Statement{body: sql}, opts) do
    read_only = Keyword.get(opts, :read_only, true)

    profile = lexical_profile(dialect)

    tokens =
      sql
      |> Sanitizer.strip_trailing_semicolon()
      |> Tokenizer.tokenize(profile)

    with :ok <- assert_single_statement(tokens),
         :ok <- assert_contained(tokens, profile),
         :ok <- assert_not_denied(tokens, read_only) do
      assert_no_side_effects(dialect, tokens, read_only)
    end
  end

  # The lexical rules of the dialect's statements, as
  # `Lotus.Source.Adapter.lexical_profile/1` has them for its adapter: the
  # profile of its query language, refined by the `:dialect_spec` of its
  # editor config. An external dialect (ClickHouse: backticks, `#` comments,
  # backslash escapes) declares its rules there; read as ANSI SQL, a denied
  # call could hide behind a quote or a comment the engine reads otherwise.
  defp lexical_profile(dialect) do
    base = Profile.for_language(dialect.query_language())

    spec =
      if function_exported?(dialect, :editor_config, 0),
        do: Map.get(dialect.editor_config(), :dialect_spec)

    Profile.from_dialect_spec(base, spec)
  end

  defp neutralize_template(sql, dialect) do
    profile = lexical_profile(dialect)

    sql
    |> OptionalClause.strip_brackets(profile)
    |> Variables.neutralize("NULL", profile)
  end

  @doc false
  def do_extract_accessed_resources(dialect, repo, %Statement{} = statement) do
    if function_exported?(dialect, :extract_accessed_resources, 2),
      do: dialect.extract_accessed_resources(repo, statement),
      else:
        {:unrestricted,
         "dialect #{inspect(dialect)} does not implement extract_accessed_resources/2"}
  end

  @doc false
  def do_apply_pagination(
        dialect,
        _repo,
        %Statement{body: sql, params: params, meta: meta} = statement,
        pagination_opts
      ) do
    base_sql = Sanitizer.strip_trailing_semicolon(sql)
    limit = Keyword.fetch!(pagination_opts, :limit)
    offset = Keyword.get(pagination_opts, :offset, 0)
    count_mode = Keyword.get(pagination_opts, :count, :none)

    param_count = length(params)

    {limit_ph, offset_ph} =
      dialect.limit_offset_placeholders(param_count + 1, param_count + 2)

    # The body stands on lines of its own, so that a line comment at its end
    # can't reach the LIMIT: the sanitizer refuses what then isn't contained.
    paged_sql =
      "SELECT * FROM (\n" <>
        base_sql <> "\n) AS lotus_sub LIMIT " <> limit_ph <> " OFFSET " <> offset_ph

    paged_params = params ++ [limit, offset]

    count_spec =
      case count_mode do
        :exact ->
          %{
            query: "SELECT COUNT(*) FROM (\n" <> base_sql <> "\n) AS lotus_sub",
            params: params
          }

        _ ->
          nil
      end

    new_meta =
      case count_spec do
        nil -> Map.delete(meta, :count_spec)
        spec -> Map.put(meta, :count_spec, spec)
      end

    %{statement | body: paged_sql, params: paged_params, meta: new_meta}
  end

  # SQL-specific preflight heuristic. Skips introspection statements
  # (EXPLAIN, SHOW, PRAGMA) that do not touch visible relations. Dialects
  # can override by implementing `needs_preflight?/1`, as the built-in ones
  # do to check the tables an EXPLAIN describes (and SQLite a PRAGMA, MySQL
  # a DESCRIBE or a SHOW COLUMNS or SHOW INDEX).
  #
  # Skipping the preflight skips column visibility, so the check errs
  # toward running it: the statement is skipped only when the first word
  # the engine reads, past comments and whitespace in the dialect's
  # lexical rules, is one of those commands as a whole word. Anything
  # else first (a parenthesis, a placeholder, an optional block, a MySQL
  # `/*! ... */` comment the engine runs) runs the preflight.
  @no_preflight_commands ~w(EXPLAIN PRAGMA SHOW)

  @doc false
  def do_needs_preflight?(dialect, %Statement{body: sql} = statement) do
    cond do
      function_exported?(dialect, :needs_preflight?, 1) ->
        dialect.needs_preflight?(statement)

      is_binary(sql) ->
        leading_command(sql, lexical_profile(dialect)) not in @no_preflight_commands

      true ->
        true
    end
  end

  defp leading_command(sql, profile) do
    sql |> Tokenizer.tokenize(profile) |> first_code_word()
  end

  defp first_code_word([{:comment, _raw} | rest]), do: first_code_word(rest)

  defp first_code_word([{:code, raw} | rest]) do
    case String.trim_leading(raw) do
      "" -> first_code_word(rest)
      code -> code |> leading_word(0) |> whole_word(rest)
    end
  end

  defp first_code_word(_tokens), do: nil

  # The ASCII letters at the head of `code`, and what follows them.
  defp leading_word(code, n) do
    case code do
      <<_::binary-size(^n), c, _::binary>> when c in ?a..?z or c in ?A..?Z ->
        leading_word(code, n + 1)

      <<word::binary-size(^n), after_word::binary>> ->
        {word, after_word}
    end
  end

  # A word is whole when an identifier character does not go on from it,
  # in this code token or (`SHOW"x"`, `SHOW{{x}}`) the token after it.
  defp whole_word({"", _after_word}, _rest), do: nil

  defp whole_word({_word, <<c, _::binary>>}, _rest)
       when c in ?0..?9 or c in [?_, ?$] or c >= 128,
       do: nil

  defp whole_word({_word, ""}, [token | _rest])
       when elem(token, 0) in [:identifier, :string, :variable, :block],
       do: nil

  defp whole_word({word, _after_word}, _rest), do: String.upcase(word)

  # Scalar substitution for Ecto-backed adapters: append value to
  # `statement.params`, replace the first `{{var_name}}` occurrence in
  # `statement.body` with the dialect's placeholder at position `idx + 1`.
  # Subsequent occurrences of the same variable are handled by further
  # calls from the caller's reduce loop.
  @doc false
  def do_substitute_variable(
        dialect,
        %Statement{body: sql, params: params} = statement,
        var_name,
        value,
        type
      )
      when is_binary(sql) do
    idx = length(params) + 1
    placeholder = dialect.param_placeholder(idx, var_name, type)
    new_sql = bind_first_placeholder(sql, dialect, var_name, placeholder)
    {:ok, %{statement | body: new_sql, params: params ++ [value]}}
  end

  # List substitution: generate one placeholder per value, join with `, `,
  # replace the first `{{var_name}}` occurrence with the group, and append
  # all values to `statement.params` in order.
  @doc false
  def do_substitute_list_variable(
        dialect,
        %Statement{body: sql, params: params} = statement,
        var_name,
        values,
        type
      )
      when is_binary(sql) and is_list(values) do
    start_idx = length(params) + 1

    placeholders =
      values
      |> Enum.with_index(start_idx)
      |> Enum.map_join(", ", fn {_value, i} -> dialect.param_placeholder(i, var_name, type) end)

    new_sql = bind_first_placeholder(sql, dialect, var_name, placeholders)
    {:ok, %{statement | body: new_sql, params: params ++ values}}
  end

  # Replaces the first `{{var_name}}` the engine would see (code or a string
  # literal, never a comment or a quoted identifier). Leaves the text alone
  # when there is none, as the params are appended either way.
  defp bind_first_placeholder(sql, dialect, var_name, replacement) do
    tokens = Tokenizer.tokenize(sql, lexical_profile(dialect))

    case Tokenizer.replace_first_variable(tokens, var_name, replacement) do
      {:ok, tokens} -> Tokenizer.to_string(tokens)
      :error -> sql
    end
  end

  # Ecto adapters validate statements by running EXPLAIN (via query_plan)
  # against the neutralized text. Callers pass a statement whose text may
  # still contain Lotus template syntax; we strip optional clauses and
  # replace {{var}} with NULL so the server can parse it.
  @doc false
  def do_validate_statement(
        dialect,
        repo,
        %Statement{body: sql} = statement,
        _opts
      )
      when is_binary(sql) do
    neutralized = neutralize_template(sql, dialect)

    case dialect.query_plan(repo, %{statement | body: neutralized}, []) do
      {:ok, _plan} -> :ok
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # SQL qualified names: split on the first "." to produce `[schema, table]`
  # or `[table]` when unqualified.
  @doc false
  def do_parse_qualified_name(name) when is_binary(name) do
    {:ok, String.split(name, ".", parts: 2)}
  end

  # SQL identifier rules: `[a-zA-Z_][a-zA-Z0-9_]*` for all kinds. Dialects
  # with stricter rules (reserved words, case sensitivity) can override
  # via `defoverridable` in their own adapter module.
  @doc false
  def do_validate_identifier(kind, value) when is_binary(value) do
    Identifier.validate_identifier(value, "#{kind} name")
  end

  # Ecto-backed adapters implement the `Lotus.Query.Filter` operators via
  # `Lotus.SQL.FilterInjector`. A dialect declares its own set with
  # `supported_filter_operators/0`; one that does not has all of them but
  # the text operators, whose `LIKE ... ESCAPE` its engine may not take.
  @doc false
  def do_supported_filter_operators(dialect) do
    if Code.ensure_loaded?(dialect) and
         function_exported?(dialect, :supported_filter_operators, 0),
       do: dialect.supported_filter_operators(),
       else: Filter.operators() -- Filter.text_operators()
  end

  # Assemble the dialect's AI context. Dialects that implement the
  # optional `ai_context/0` callback supply their own (Postgres/MySQL/
  # SQLite with dialect-specific syntax notes + error patterns); dialects
  # that don't get a generic-SQL context synthesized from `query_language/0`.
  @doc false
  def do_ai_context(dialect) do
    if function_exported?(dialect, :ai_context, 0) do
      dialect.ai_context()
    else
      {:ok,
       %{
         language: dialect.query_language(),
         example_query: "SELECT column1 FROM table_name LIMIT 10",
         syntax_notes: "Use standard SQL.",
         error_patterns: []
       }}
    end
  end

  # Resolve Lotus template syntax so the statement is parseable by the
  # dialect's EXPLAIN variant without bound params. SQL gets "NULL" for
  # `{{var}}` placeholders; `[[...]]` optional blocks are kept (inner
  # content retained so all clauses are visible to the planner).
  @doc false
  def do_prepare_for_analysis(dialect, %Statement{body: sql} = statement) when is_binary(sql) do
    {:ok, %{statement | body: neutralize_template(sql, dialect), params: []}}
  end

  def do_prepare_for_analysis(_dialect, _statement), do: {:error, :non_text_statement}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Sanitization helpers
  # ---------------------------------------------------------------------------

  # Allow a single statement with an optional trailing semicolon (already
  # stripped by the caller). Reject any semicolon the tokenizer sees in code.
  defp assert_single_statement(tokens) do
    if tokens |> Tokenizer.code() |> Enum.any?(&String.contains?(&1, ";")) do
      {:error, "Only a single statement is allowed"}
    else
      :ok
    end
  end

  # Lotus wraps a statement in its own (a window, a count), which holds only
  # while the statement closes every parenthesis it opens, none it didn't,
  # and every comment.
  defp assert_contained(tokens, profile) do
    depths =
      tokens
      |> Tokenizer.code()
      |> Enum.flat_map(&String.graphemes/1)
      |> Enum.scan(0, fn
        "(", depth -> depth + 1
        ")", depth -> depth - 1
        _char, depth -> depth
      end)

    if Enum.any?(depths, &(&1 < 0)) or List.last(depths, 0) != 0 or
         open_comment?(List.last(tokens), profile),
       do: {:error, "Query has unbalanced parentheses or an unclosed comment"},
       else: :ok
  end

  # A block comment the tokenizer didn't close runs to the end of the input.
  # Where comments nest, a closed one has as many `*/` as `/*`.
  defp open_comment?({:comment, "/*" <> _ = raw}, %Profile{nested_block_comments?: true}),
    do: comment_depth(raw, 0) != 0

  defp open_comment?({:comment, "/*" <> rest}, _profile), do: not String.ends_with?(rest, "*/")
  defp open_comment?(_token, _profile), do: false

  defp comment_depth(<<"/*", rest::binary>>, depth), do: comment_depth(rest, depth + 1)
  defp comment_depth(<<"*/", rest::binary>>, depth), do: comment_depth(rest, depth - 1)
  defp comment_depth(<<_, rest::binary>>, depth), do: comment_depth(rest, depth)
  defp comment_depth(<<>>, depth), do: depth

  defp assert_not_denied(_tokens, false = _read_only), do: :ok

  defp assert_not_denied(tokens, _read_only) do
    if tokens |> Tokenizer.code() |> Enum.any?(&Regex.match?(@deny, &1)),
      do: {:error, "Only read-only queries are allowed"},
      else: :ok
  end

  # Commands a read-only run may not start with: they change the session or
  # the transaction rather than read (SET, LISTEN, PREPARE, DECLARE, COMMIT,
  # USE, ...), or reach outside the database (COPY, LOAD, DO).
  @denied_commands ~w(set reset discard listen unlisten notify prepare execute deallocate
                      declare fetch move close copy do load begin start commit rollback end
                      abort savepoint release checkpoint reindex cluster refresh comment
                      security import handler flush kill install uninstall shutdown rename
                      replace attach detach use merge)

  # PRAGMAs that only read, in their function form (`PRAGMA table_info(t)`).
  @read_pragmas ~w(table_info table_xinfo table_list index_list index_info index_xinfo
                   foreign_key_list foreign_key_check database_list collation_list
                   function_list module_list pragma_list compile_options integrity_check
                   quick_check)

  defp assert_no_side_effects(_dialect, _tokens, false = _read_only), do: :ok

  defp assert_no_side_effects(dialect, tokens, _read_only) do
    tokens = unescape_names(tokens)
    code = code_view(tokens)

    with :ok <- assert_read_command(code, tokens) do
      assert_no_denied_function(code, dialect)
    end
  end

  @command ~r/\A[\s(]*([A-Za-z_]+)(.*)\z/s

  defp assert_read_command(code, tokens) do
    case Regex.run(@command, code) do
      [_, command, rest] -> check_command(String.downcase(command), rest, tokens)
      _ -> :ok
    end
  end

  defp check_command(command, _rest, _tokens) when command in @denied_commands,
    do: {:error, "Only read-only queries are allowed: #{String.upcase(command)} is not"}

  # SQLite also reads a string literal as a PRAGMA's name (`PRAGMA 'name'`),
  # so the name is read with literals as their text. A PRAGMA reads only
  # without a value, or in the function form of a pragma that reads; any
  # other, or one whose name can't be read, is refused.
  defp check_command("pragma", _rest, tokens) do
    [_, _command, rest] = Regex.run(@command, code_view(tokens, :literal_names))

    case Regex.run(~r/\A\s*(?:\w+\s*\.\s*)?(\w+)\s*(.?)/s, rest) do
      [_, _name, ""] -> :ok
      [_, name, "("] -> if String.downcase(name) in @read_pragmas, do: :ok, else: pragma_error()
      _ -> pragma_error()
    end
  end

  defp check_command(_command, _rest, _tokens), do: :ok

  defp pragma_error, do: {:error, "Only read-only queries are allowed: this PRAGMA sets a value"}

  defp assert_no_denied_function(code, dialect) do
    names =
      if function_exported?(dialect, :denied_functions, 0),
        do: dialect.denied_functions(),
        else: []

    with [_ | _] <- names,
         [_, name] <- Regex.run(denied_functions_regex(names), code) do
      {:error, "Only read-only queries are allowed: #{String.downcase(name)}() is not"}
    else
      _ -> :ok
    end
  end

  defp denied_functions_regex(names) do
    alternatives =
      Enum.map_join(names, "|", fn name ->
        name |> Regex.escape() |> String.replace("\\*", "\\w*")
      end)

    Regex.compile!("(?<![\\w$])(#{alternatives})\\s*\\(", "i")
  end

  # PostgreSQL's `U&"..."` spells a name with Unicode escapes
  # (`U&"set\005fconfig"`, or with the escape character `UESCAPE` gives): the
  # checks read the name it spells.
  defp unescape_names([{:code, raw}, {:identifier, quoted} | rest]) do
    case Regex.run(~r/\A(.*?)(?<![\w$])[uU]&\z/s, raw) do
      [_, before] ->
        {escape, rest} = escape_character(rest)
        name = quoted |> String.slice(1..-2//1) |> decode_escapes(escape)
        [{:code, before}, {:identifier, ~s("#{name}")} | unescape_names(rest)]

      nil ->
        [{:code, raw} | unescape_names([{:identifier, quoted} | rest])]
    end
  end

  defp unescape_names([{:block, inner} | rest]),
    do: [{:block, unescape_names(inner)} | unescape_names(rest)]

  defp unescape_names([token | rest]), do: [token | unescape_names(rest)]
  defp unescape_names([]), do: []

  defp escape_character([{:code, code}, {:string, <<?', char::utf8, ?'>>} | rest]) do
    if Regex.match?(~r/\A\s*UESCAPE\s*\z/i, code),
      do: {<<char::utf8>>, [{:code, " "} | rest]},
      else: {"\\", [{:code, code}, {:string, <<?', char::utf8, ?'>>} | rest]}
  end

  defp escape_character(rest), do: {"\\", rest}

  defp decode_escapes(name, escape) do
    size = byte_size(escape)

    case name do
      "" ->
        ""

      <<^escape::binary-size(^size), ^escape::binary-size(^size), rest::binary>> ->
        escape <> decode_escapes(rest, escape)

      <<^escape::binary-size(^size), "+", hex::binary-size(6), rest::binary>> ->
        decode_codepoint(hex, escape <> "+" <> hex) <> decode_escapes(rest, escape)

      <<^escape::binary-size(^size), hex::binary-size(4), rest::binary>> ->
        decode_codepoint(hex, escape <> hex) <> decode_escapes(rest, escape)

      <<char::utf8, rest::binary>> ->
        <<char::utf8>> <> decode_escapes(rest, escape)
    end
  end

  defp decode_codepoint(hex, raw) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} when codepoint in 0..0x10FFFF -> <<codepoint::utf8>>
      _ -> raw
    end
  rescue
    ArgumentError -> raw
  end

  # The statement as the engine reads it, for the checks above: code as is,
  # a quoted identifier as its bare name (`"set_config"(` calls set_config)
  # set apart from the words around it, literals and placeholders as
  # stand-ins, comments as a space. With `:literal_names`, a string literal
  # is its text, as where SQLite takes it for a name.
  defp code_view(tokens, literals \\ :stand_in) do
    tokens
    |> Enum.map(fn
      {:code, raw} -> raw
      {:identifier, raw} -> [" ", String.slice(raw, 1..-2//1), " "]
      {:string, raw} -> literal_view(raw, literals)
      {:variable, _name, _raw} -> " NULL "
      {:comment, _raw} -> " "
      {:block, inner} -> code_view(inner, literals)
    end)
    |> IO.iodata_to_binary()
  end

  defp literal_view(_raw, :stand_in), do: " '' "
  defp literal_view(raw, :literal_names), do: [" ", String.slice(raw, 1..-2//1), " "]

  # ---------------------------------------------------------------------------
  # SQL parsing utilities (shared by dialect extract_accessed_resources impls)
  # ---------------------------------------------------------------------------

  # These read the statement through `Lotus.Query.Tokenizer`, so a `FROM`,
  # `--` or `/*` inside a string literal, a quoted identifier or a comment
  # is not taken for code. `profile` defaults to ANSI SQL; a dialect passes
  # its own (`Profile.for_language/1`) for its quotes and comments.

  @doc false
  # The statement as the engine reads it past comments, each a space, for a
  # dialect that reads its leading words (`EXPLAIN`, `SHOW`, `PRAGMA`).
  @spec statement_text(String.t(), Profile.t()) :: String.t()
  def statement_text(sql, %Profile{} = profile) do
    sql
    |> Tokenizer.tokenize(profile)
    |> Enum.map(fn
      {:comment, _raw} -> {:code, " "}
      token -> token
    end)
    |> Tokenizer.to_string()
  end

  @doc false
  @spec parse_alias_map(String.t(), Profile.t()) :: %{String.t() => String.t()}
  def parse_alias_map(sql, %Profile{} = profile \\ %Profile{}) do
    sql |> sql_lexemes(profile) |> alias_pairs(%{})
  end

  # `FROM <name> [AS] <name>` and `JOIN <name> [AS] <name>` map the second
  # name to the first. A name is a word or a quoted identifier.
  defp alias_pairs([{:word, keyword} | rest], acc) do
    acc =
      with true <- String.downcase(keyword) in ["from", "join"],
           [base | after_base] <- rest,
           {:ok, base} <- lexeme_name(base),
           {:ok, alias_name} <- alias_after(after_base) do
        Map.put(acc, alias_name, base)
      else
        _ -> acc
      end

    alias_pairs(rest, acc)
  end

  defp alias_pairs([_lexeme | rest], acc), do: alias_pairs(rest, acc)
  defp alias_pairs([], acc), do: acc

  defp alias_after([{:word, as}, name | _rest] = lexemes) do
    with "as" <- String.downcase(as), {:ok, alias_name} <- lexeme_name(name) do
      {:ok, alias_name}
    else
      _ -> lexemes |> hd() |> lexeme_name()
    end
  end

  defp alias_after([name | _rest]), do: lexeme_name(name)
  defp alias_after([]), do: :error

  defp lexeme_name({:word, word}), do: {:ok, word}
  defp lexeme_name({:identifier, raw}), do: {:ok, unquote_identifier(raw)}
  defp lexeme_name(_lexeme), do: :error

  @doc false
  @spec strip_sql_comments(String.t(), Profile.t()) :: String.t()
  def strip_sql_comments(s, %Profile{} = profile \\ %Profile{}) do
    s
    |> Tokenizer.tokenize(profile)
    |> strip_comment_tokens()
    |> IO.iodata_to_binary()
  end

  # A line comment goes, leaving its line break; a block comment becomes a
  # space, as the engine reads it, so `a/**/b` stays two words.
  defp strip_comment_tokens(tokens) do
    Enum.map(tokens, fn
      {:comment, "/*" <> _} -> " "
      {:comment, _raw} -> ""
      {:block, inner} -> ["[[", strip_comment_tokens(inner), "]]"]
      token -> Tokenizer.to_iodata([token])
    end)
  end

  @typedoc false
  @type sql_lexeme ::
          {:word, String.t()} | {:identifier, String.t()} | {:punct, String.t()} | :literal

  @doc false
  # The code of `sql` as words, quoted identifiers (raw, quotes included)
  # and single punctuation characters. A string literal or a placeholder is
  # `:literal`; a comment is dropped; an optional block's contents are
  # inlined.
  @spec sql_lexemes(String.t(), Profile.t()) :: [sql_lexeme()]
  def sql_lexemes(sql, %Profile{} = profile \\ %Profile{}) when is_binary(sql) do
    sql |> Tokenizer.tokenize(profile) |> lexemes_of_tokens()
  end

  defp lexemes_of_tokens(tokens) do
    Enum.flat_map(tokens, fn
      {:code, raw} -> code_lexemes(raw)
      {:identifier, raw} -> [{:identifier, raw}]
      {:string, _raw} -> [:literal]
      {:variable, _name, _raw} -> [:literal]
      {:comment, _raw} -> []
      {:block, inner} -> lexemes_of_tokens(inner)
    end)
  end

  defp code_lexemes(raw) do
    for [piece] <- Regex.scan(~r/[\w$]+|[^\w$\s]/u, raw) do
      if Regex.match?(~r/\A[\w$]+\z/u, piece), do: {:word, piece}, else: {:punct, piece}
    end
  end

  @doc false
  # The name a quoted identifier spells: `"a""b"` is `a"b`, `` `t` `` is
  # `t`, `[my col]` is `my col`. One left open at the end of the input
  # runs to the end.
  @spec unquote_identifier(String.t()) :: String.t()
  def unquote_identifier("[" <> rest), do: strip_closing(rest, "]")

  def unquote_identifier(<<quote::binary-size(1), rest::binary>>) do
    rest |> strip_closing(quote) |> String.replace(quote <> quote, quote)
  end

  defp strip_closing(rest, closing) do
    size = byte_size(rest)

    if size > 0 and binary_part(rest, size - 1, 1) == closing,
      do: binary_part(rest, 0, size - 1),
      else: rest
  end

  @doc false
  def normalize_ident(<<"\"", rest::binary>>) do
    rest |> String.trim_trailing(~s|"|) |> String.replace(~s|""|, ~s|"|)
  end

  def normalize_ident(s), do: s

  @doc false
  def resolve_alias(name, alias_map), do: Map.get(alias_map, name, name)
end
