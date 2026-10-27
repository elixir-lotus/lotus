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
  @deny ~r/\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE|VACUUM|ANALYZE|CALL|LOCK|OUTFILE|DUMPFILE)\b/i

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

    tokens =
      sql
      |> Sanitizer.strip_trailing_semicolon()
      |> Tokenizer.tokenize(lexical_profile(dialect))

    with :ok <- assert_single_statement(tokens),
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

    paged_sql =
      "SELECT * FROM (" <>
        base_sql <> ") AS lotus_sub LIMIT " <> limit_ph <> " OFFSET " <> offset_ph

    paged_params = params ++ [limit, offset]

    count_spec =
      case count_mode do
        :exact ->
          %{
            query: "SELECT COUNT(*) FROM (" <> base_sql <> ") AS lotus_sub",
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
  # can override by implementing `needs_preflight?/1`.
  @doc false
  def do_needs_preflight?(dialect, %Statement{body: sql} = statement) do
    cond do
      function_exported?(dialect, :needs_preflight?, 1) ->
        dialect.needs_preflight?(statement)

      is_binary(sql) ->
        s =
          sql
          |> String.replace(~r/--.*$/m, "")
          |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
          |> String.trim_leading()
          |> upcase_head(12)

        not (String.starts_with?(s, "EXPLAIN") or
               String.starts_with?(s, "PRAGMA") or
               String.starts_with?(s, "SHOW"))

      true ->
        true
    end
  end

  defp upcase_head(s, n) do
    {head, tail} = String.split_at(s, n)
    String.upcase(head) <> tail
  end

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
    code = code_view(tokens)

    with :ok <- assert_read_command(code) do
      assert_no_denied_function(code, dialect)
    end
  end

  defp assert_read_command(code) do
    case Regex.run(~r/\A[\s(]*([A-Za-z_]+)(.*)\z/s, code) do
      [_, command, rest] -> check_command(String.downcase(command), rest)
      _ -> :ok
    end
  end

  defp check_command(command, _rest) when command in @denied_commands,
    do: {:error, "Only read-only queries are allowed: #{String.upcase(command)} is not"}

  defp check_command("pragma", rest) do
    name = ~r/\A\s*(?:\w+\s*\.\s*)?(\w+)\s*(.?)/ |> Regex.run(rest) |> pragma_form()

    case name do
      {_name, "="} -> pragma_error()
      {name, "("} -> if String.downcase(name) in @read_pragmas, do: :ok, else: pragma_error()
      _ -> :ok
    end
  end

  defp check_command(_command, _rest), do: :ok

  defp pragma_form([_, name, next]), do: {name, next}
  defp pragma_form(_), do: nil

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

  # The statement as the engine reads it, for the checks above: code as is,
  # a quoted identifier as its bare name (`"set_config"(` calls set_config),
  # literals and placeholders as stand-ins, comments as a space.
  defp code_view(tokens) do
    tokens
    |> Enum.map(fn
      {:code, raw} -> raw
      {:identifier, raw} -> String.slice(raw, 1..-2//1)
      {:string, _raw} -> " '' "
      {:variable, _name, _raw} -> " NULL "
      {:comment, _raw} -> " "
      {:block, inner} -> code_view(inner)
    end)
    |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # SQL parsing utilities (shared by dialect extract_accessed_resources impls)
  # ---------------------------------------------------------------------------

  @doc false
  def parse_alias_map(sql) do
    s = strip_sql_comments(sql)

    rx_from = ~r/\bFROM\s+("?[A-Za-z0-9_]+"?)\s+(?:AS\s+)?("?[A-Za-z0-9_]+"?)/i
    rx_join = ~r/\bJOIN\s+("?[A-Za-z0-9_]+"?)\s+(?:AS\s+)?("?[A-Za-z0-9_]+"?)/i

    [rx_from, rx_join]
    |> Enum.flat_map(&Regex.scan(&1, s))
    |> Enum.reduce(%{}, fn
      [_, base, alias_name], acc ->
        base = normalize_ident(base)
        alias_name = normalize_ident(alias_name)
        if base == "(", do: acc, else: Map.put(acc, alias_name, base)

      _, acc ->
        acc
    end)
  end

  @doc false
  def strip_sql_comments(s) do
    s
    |> String.replace(~r/--.*$/m, "")
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
  end

  @doc false
  def normalize_ident(<<"\"", rest::binary>>) do
    rest |> String.trim_trailing(~s|"|) |> String.replace(~s|""|, ~s|"|)
  end

  def normalize_ident(s), do: s

  @doc false
  def resolve_alias(name, alias_map), do: Map.get(alias_map, name, name)
end
