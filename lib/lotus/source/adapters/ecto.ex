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

  ## Extending with custom Ecto-backed adapters

  External libraries can create Ecto-backed adapters by writing a dialect
  module and a one-liner adapter:

      defmodule LotusMSSql.Adapter do
        use Lotus.Source.Adapters.Ecto, dialect: LotusMSSql.Dialect
      end

  The `use` macro injects default implementations for all
  `Lotus.Source.Adapter` callbacks, delegating shared Ecto logic to helper
  functions in this module and dialect-specific callbacks to the provided
  `:dialect` module. All callbacks are `defoverridable`.
  """

  @behaviour Lotus.Source.Adapter

  alias Lotus.Query.Filter
  alias Lotus.Query.OptionalClause
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto.Dialects
  alias Lotus.Source.Adapters.Ecto.SQL.Identifier
  alias Lotus.Source.Adapters.Ecto.SQL.Sanitizer
  alias Lotus.Variables

  @default_dialect Dialects.Default

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

    quote do
      @behaviour Lotus.Source.Adapter

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

      defoverridable Lotus.Source.Adapter
    end
  end

  defp registration_callbacks do
    quote do
      @impl true
      def can_handle?(repo) when is_atom(repo) do
        function_exported?(repo, :__adapter__, 0) and
          repo.__adapter__() == @dialect.ecto_adapter()
      end

      def can_handle?(_), do: false

      @impl true
      def wrap(name, repo_module) when is_binary(name) and is_atom(repo_module) do
        %Adapter{
          name: name,
          module: __MODULE__,
          state: repo_module,
          source_type: @dialect.source_type()
        }
      end
    end
  end

  defp execution_callbacks do
    quote do
      @impl true
      def execute_query(repo, sql, params, opts) do
        EctoAdapter.do_execute_query(@dialect, repo, sql, params, opts)
      end

      @impl true
      def transaction(repo, fun, opts) do
        @dialect.execute_in_transaction(repo, fn -> fun.(repo) end, opts)
      end
    end
  end

  defp introspection_callbacks do
    quote do
      @impl true
      def list_schemas(repo) do
        {:ok, @dialect.list_schemas(repo)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def list_tables(repo, schemas, opts) do
        include_views? = Keyword.get(opts, :include_views, false)
        {:ok, @dialect.list_tables(repo, schemas, include_views?)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def describe_table(repo, schema, table) do
        {:ok, @dialect.describe_table(repo, schema, table)}
      rescue
        e -> {:error, Exception.message(e)}
      end

      @impl true
      def resolve_table_namespace(repo, table, schemas) do
        {:ok, @dialect.resolve_table_namespace(repo, table, schemas)}
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
      def query_plan(repo, sql, params, opts),
        do: @dialect.query_plan(repo, sql, params, opts)
    end
  end

  defp visibility_callbacks do
    quote do
      @impl true
      def builtin_denies(repo), do: @dialect.builtin_denies(repo)

      @impl true
      def builtin_schema_denies(repo), do: @dialect.builtin_schema_denies(repo)

      @impl true
      def default_schemas(repo), do: @dialect.default_schemas(repo)
    end
  end

  defp lifecycle_callbacks do
    quote do
      @impl true
      def health_check(repo), do: EctoAdapter.do_health_check(repo)

      @impl true
      def disconnect(_repo), do: :ok

      @impl true
      def format_error(_repo, error), do: @dialect.format_error(error)

      @impl true
      def handled_errors(_repo), do: @dialect.handled_errors()
    end
  end

  defp pipeline_callbacks do
    quote do
      @impl true
      def sanitize_query(_repo, statement, opts),
        do: EctoAdapter.do_sanitize_query(statement, opts)

      @impl true
      def transform_bound_query(_repo, statement, _opts), do: statement

      @impl true
      def extract_accessed_resources(repo, statement) do
        EctoAdapter.do_extract_accessed_resources(@dialect, repo, statement)
      end

      @impl true
      def apply_pagination(repo, statement, pagination_opts) do
        EctoAdapter.do_apply_pagination(@dialect, repo, statement, pagination_opts)
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
      def validate_statement(repo, statement, opts),
        do: EctoAdapter.do_validate_statement(@dialect, repo, statement, opts)

      @impl true
      def parse_qualified_name(_repo, name), do: EctoAdapter.do_parse_qualified_name(name)

      @impl true
      def validate_identifier(_repo, kind, value),
        do: EctoAdapter.do_validate_identifier(kind, value)

      @impl true
      def supported_filter_operators(_repo), do: EctoAdapter.do_supported_filter_operators()

      @impl true
      def ai_context(_repo), do: EctoAdapter.do_ai_context(@dialect)

      @impl true
      def prepare_for_analysis(_repo, statement),
        do: EctoAdapter.do_prepare_for_analysis(statement)
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

  @doc """
  Wraps an `Ecto.Repo` module in an `%Adapter{}` struct.

  The resulting adapter delegates all callbacks to the appropriate source
  implementation based on the repo's underlying Ecto adapter.

  ## Parameters

    * `name` — a human-readable identifier (e.g. `"main"`, `"warehouse"`)
    * `repo_module` — the Ecto.Repo module (e.g. `MyApp.Repo`)

  ## Examples

      iex> adapter = Lotus.Source.Adapters.Ecto.wrap("main", MyApp.Repo)
      %Lotus.Source.Adapter{name: "main", module: Lotus.Source.Adapters.Ecto, ...}
  """
  @impl true
  @spec wrap(String.t(), module()) :: Adapter.t()
  def wrap(name, repo_module) when is_binary(name) and is_atom(repo_module) do
    case Enum.find(@builtin_ecto_adapters, & &1.can_handle?(repo_module)) do
      nil ->
        # Guard the fallback path: `can_handle?/1` is broad (any atom), so
        # without this check we'd happily wrap a non-Ecto atom like :typoed_name
        # and fail later with an opaque error during query execution.
        unless function_exported?(repo_module, :__adapter__, 0) do
          raise ArgumentError,
                "Cannot wrap #{inspect(repo_module)} as an Ecto source — " <>
                  "the module does not export __adapter__/0. Either register " <>
                  "a custom `source_adapters` entry whose can_handle?/1 matches " <>
                  "this source, or pass an `Ecto.Repo` module."
        end

        %Adapter{
          name: name,
          module: __MODULE__,
          state: repo_module,
          source_type: @default_dialect.source_type()
        }

      adapter_mod ->
        adapter_mod.wrap(name, repo_module)
    end
  end

  @doc """
  Whether this adapter can handle the given data source entry.

  Returns `true` for any module that exports `__adapter__/0`. This is
  intentionally broad — it acts as a catch-all fallback for Ecto repos
  that don't match a more specific per-dialect adapter. The resolver
  checks per-dialect adapters first (via `builtin_adapters/0` and
  `source_adapters` config), so this only matches repos with unknown
  Ecto adapters.
  """
  @impl true
  @spec can_handle?(term()) :: boolean()
  def can_handle?(repo) when is_atom(repo) do
    function_exported?(repo, :__adapter__, 0)
  end

  def can_handle?(_), do: false

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
  def execute_query(repo, sql, params, opts) do
    do_execute_query(@default_dialect, repo, sql, params, opts)
  end

  @impl true
  def transaction(repo, fun, opts) do
    @default_dialect.execute_in_transaction(repo, fn -> fun.(repo) end, opts)
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Introspection (wrap bare returns in {:ok, _} tuples)
  # ---------------------------------------------------------------------------

  @impl true
  def list_schemas(repo) do
    {:ok, @default_dialect.list_schemas(repo)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def list_tables(repo, schemas, opts) do
    include_views? = Keyword.get(opts, :include_views, false)
    {:ok, @default_dialect.list_tables(repo, schemas, include_views?)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def describe_table(repo, schema, table) do
    {:ok, @default_dialect.describe_table(repo, schema, table)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def resolve_table_namespace(repo, table, schemas) do
    {:ok, @default_dialect.resolve_table_namespace(repo, table, schemas)}
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
  def query_plan(repo, sql, params, opts) do
    @default_dialect.query_plan(repo, sql, params, opts)
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Safety & Visibility (delegate to source impl)
  # ---------------------------------------------------------------------------

  @impl true
  def builtin_denies(repo) do
    @default_dialect.builtin_denies(repo)
  end

  @impl true
  def builtin_schema_denies(repo) do
    @default_dialect.builtin_schema_denies(repo)
  end

  @impl true
  def default_schemas(repo) do
    @default_dialect.default_schemas(repo)
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def health_check(repo), do: do_health_check(repo)

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

  @impl true
  def handled_errors(_repo) do
    @default_dialect.handled_errors()
  end

  # ---------------------------------------------------------------------------
  # Callbacks — Pipeline (Query Processing)
  # ---------------------------------------------------------------------------

  # Deny list for dangerous operations (defense-in-depth).
  # Skipped when `read_only: false` is passed in opts.
  @deny ~r/\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE|VACUUM|ANALYZE|CALL|LOCK)\b/i

  @impl true
  def sanitize_query(_repo, statement, opts), do: do_sanitize_query(statement, opts)

  @impl true
  def transform_bound_query(_repo, statement, _opts), do: statement

  @impl true
  def extract_accessed_resources(repo, statement) do
    do_extract_accessed_resources(@default_dialect, repo, statement)
  end

  @impl true
  def apply_pagination(repo, statement, pagination_opts) do
    do_apply_pagination(@default_dialect, repo, statement, pagination_opts)
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
  def validate_statement(repo, statement, opts),
    do: do_validate_statement(@default_dialect, repo, statement, opts)

  @impl true
  def parse_qualified_name(_repo, name), do: do_parse_qualified_name(name)

  @impl true
  def validate_identifier(_repo, kind, value), do: do_validate_identifier(kind, value)

  @impl true
  def supported_filter_operators(_repo), do: do_supported_filter_operators()

  @impl true
  def ai_context(_repo), do: do_ai_context(@default_dialect)

  @impl true
  def prepare_for_analysis(_repo, statement), do: do_prepare_for_analysis(statement)

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
        if search_path do
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
  def do_health_check(repo) do
    case repo.query("SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, err} -> {:error, err}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  def do_sanitize_query(%Statement{text: sql}, opts) do
    read_only = Keyword.get(opts, :read_only, true)

    with :ok <- assert_single_statement(sql) do
      assert_not_denied(sql, read_only)
    end
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
        %Statement{text: sql, params: params, meta: meta} = statement,
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

    %{statement | text: paged_sql, params: paged_params, meta: new_meta}
  end

  # SQL-specific preflight heuristic. Skips introspection statements
  # (EXPLAIN, SHOW, PRAGMA) that do not touch visible relations. Dialects
  # can override by implementing `needs_preflight?/1`.
  @doc false
  def do_needs_preflight?(dialect, %Statement{text: sql} = statement) do
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
  # `statement.text` with the dialect's placeholder at position `idx + 1`.
  # Subsequent occurrences of the same variable are handled by further
  # calls from the caller's reduce loop.
  @doc false
  def do_substitute_variable(
        dialect,
        %Statement{text: sql, params: params} = statement,
        var_name,
        value,
        type
      )
      when is_binary(sql) do
    idx = length(params) + 1
    placeholder = dialect.param_placeholder(idx, var_name, type)
    new_sql = String.replace(sql, "{{#{var_name}}}", placeholder, global: false)
    {:ok, %{statement | text: new_sql, params: params ++ [value]}}
  end

  # List substitution: generate one placeholder per value, join with `, `,
  # replace the first `{{var_name}}` occurrence with the group, and append
  # all values to `statement.params` in order.
  @doc false
  def do_substitute_list_variable(
        dialect,
        %Statement{text: sql, params: params} = statement,
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

    new_sql = String.replace(sql, "{{#{var_name}}}", placeholders, global: false)
    {:ok, %{statement | text: new_sql, params: params ++ values}}
  end

  # Ecto adapters validate statements by running EXPLAIN (via query_plan)
  # against the neutralized text. Callers pass a statement whose text may
  # still contain Lotus template syntax; we strip optional clauses and
  # replace {{var}} with NULL so the server can parse it.
  @doc false
  def do_validate_statement(
        dialect,
        repo,
        %Statement{text: sql, params: params},
        _opts
      )
      when is_binary(sql) do
    neutralized =
      sql
      |> OptionalClause.strip_brackets()
      |> Variables.neutralize("NULL")

    case dialect.query_plan(repo, neutralized, params, []) do
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

  # Ecto-backed adapters implement all `Lotus.Query.Filter` operators via
  # `Lotus.Source.Adapters.Ecto.SQL.FilterInjector`. Dialects may override to declare a narrower
  # set (e.g. if an engine lacks regex LIKE support).
  @doc false
  def do_supported_filter_operators, do: Filter.operators()

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
  def do_prepare_for_analysis(%Statement{text: sql} = statement) when is_binary(sql) do
    prepared =
      sql
      |> OptionalClause.strip_brackets()
      |> Variables.neutralize("NULL")

    {:ok, %{statement | text: prepared, params: []}}
  end

  def do_prepare_for_analysis(_statement), do: {:error, :non_text_statement}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Sanitization helpers
  # ---------------------------------------------------------------------------

  # Allow a single statement with an optional trailing semicolon.
  # Reject any additional top-level semicolons (outside strings/comments).
  defp assert_single_statement(sql) do
    s = String.trim(sql)

    s =
      if String.ends_with?(s, ";") do
        s
        |> String.trim_trailing()
        |> String.trim_trailing(";")
        |> String.trim_trailing()
      else
        s
      end

    if has_top_level_semicolon?(s) do
      {:error, "Only a single statement is allowed"}
    else
      :ok
    end
  end

  defp has_top_level_semicolon?(bin), do: scan_semicolons(bin, :code)

  # State machine that skips semicolons inside:
  # - single-quoted strings
  # - double-quoted identifiers
  # - PostgreSQL dollar-quoted strings ($tag$ ... $tag$ or $ ... $)
  # - line comments (-- ...\n)
  # - block comments (/* ... */)
  defp scan_semicolons(<<>>, _state), do: false

  defp scan_semicolons(<<?;, _::binary>>, :code), do: true

  defp scan_semicolons(<<"--", rest::binary>>, :code),
    do: scan_semicolons(skip_to_eol(rest), :code)

  defp scan_semicolons(<<"/*", rest::binary>>, :code),
    do: scan_semicolons(skip_block_comment(rest), :code)

  defp scan_semicolons(<<"'", rest::binary>>, :code),
    do: scan_semicolons(skip_single_quoted(rest), :code)

  defp scan_semicolons(<<"\"", rest::binary>>, :code),
    do: scan_semicolons(skip_double_quoted(rest), :code)

  defp scan_semicolons(<<"$", rest::binary>>, :code) do
    case take_dollar_tag(rest, "") do
      {:tag, tag, after_tag} -> scan_semicolons(skip_dollar_quoted(after_tag, tag), :code)
      :no_tag -> scan_semicolons(rest, :code)
    end
  end

  defp scan_semicolons(<<_::utf8, rest::binary>>, :code),
    do: scan_semicolons(rest, :code)

  defp skip_to_eol(<<>>), do: <<>>
  defp skip_to_eol(<<"\n", rest::binary>>), do: rest
  defp skip_to_eol(<<_::utf8, rest::binary>>), do: skip_to_eol(rest)

  defp skip_block_comment(rest), do: skip_block_comment(rest, 1)

  defp skip_block_comment(<<>>, _depth), do: <<>>
  defp skip_block_comment(<<"*/", rest::binary>>, 1), do: rest
  defp skip_block_comment(<<"*/", rest::binary>>, depth), do: skip_block_comment(rest, depth - 1)
  defp skip_block_comment(<<"/*", rest::binary>>, depth), do: skip_block_comment(rest, depth + 1)
  defp skip_block_comment(<<_::utf8, rest::binary>>, depth), do: skip_block_comment(rest, depth)

  defp skip_single_quoted(<<>>), do: <<>>
  defp skip_single_quoted(<<"''", rest::binary>>), do: skip_single_quoted(rest)
  defp skip_single_quoted(<<"'", rest::binary>>), do: rest
  defp skip_single_quoted(<<_::utf8, rest::binary>>), do: skip_single_quoted(rest)

  defp skip_double_quoted(<<>>), do: <<>>
  defp skip_double_quoted(<<"\"\"", rest::binary>>), do: skip_double_quoted(rest)
  defp skip_double_quoted(<<"\"", rest::binary>>), do: rest
  defp skip_double_quoted(<<_::utf8, rest::binary>>), do: skip_double_quoted(rest)

  defp take_dollar_tag(<<"$", rest::binary>>, acc), do: {:tag, acc, rest}

  defp take_dollar_tag(<<c, rest::binary>>, acc)
       when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_,
       do: take_dollar_tag(rest, <<acc::binary, c>>)

  defp take_dollar_tag(_, _), do: :no_tag

  defp skip_dollar_quoted(bin, tag) do
    closer = "$" <> tag <> "$"

    case :binary.match(bin, closer) do
      :nomatch -> <<>>
      {pos, len} -> :binary.part(bin, pos + len, byte_size(bin) - pos - len)
    end
  end

  defp assert_not_denied(_sql, false = _read_only), do: :ok

  defp assert_not_denied(sql, _read_only) do
    if Regex.match?(@deny, sql), do: {:error, "Only read-only queries are allowed"}, else: :ok
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
