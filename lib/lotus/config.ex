defmodule Lotus.Config do
  @moduledoc """
  Configuration management for Lotus.

  Handles loading and validating configuration from the application environment
  using `NimbleOptions`.

  ## Required Configuration

  Lotus requires a storage repository where it will store query definitions:

      config :lotus,
        storage_repo: MyApp.Repo  # Where Lotus stores its query definitions

  ## Data Sources Configuration

  Configure named data sources that Lotus can execute queries against:

      config :lotus,
        data_sources: %{
          "primary" => MyApp.Repo,
          "analytics" => MyApp.AnalyticsRepo,
          "warehouse" => MyApp.WarehouseRepo
        }

  ## Visibility Configuration

  Control which schemas and tables are accessible through Lotus with visibility rules:

      config :lotus,
        # Schema-level rules (higher precedence)
        schema_visibility: %{
          postgres: [
            allow: ["public", ~r/^tenant_/],  # Only public + tenant schemas
            deny: ["legacy"]                  # Block legacy schema
          ],
          mysql: [
            # In MySQL, schemas = databases
            allow: ["app_db", "analytics_db"],
            deny: ["staging_db"]
          ]
        },

        # Table-level rules (lower precedence)
        table_visibility: %{
          default: [
            deny: ["user_passwords", "api_keys", ~r/^audit_/]
          ],
          postgres: [
            allow: [
              {"public", ~r/^dim_/},      # Dimension tables only
              {"analytics", ~r/.*/}       # All analytics tables
            ]
          ]
        }

  **Key Principle**: Schema visibility gates table visibility. If a schema is denied,
  all tables within it are blocked regardless of table-level rules.

  **Database-Specific Schema Behavior**:

  - **PostgreSQL**: True namespaced schemas within a database (`public`, `reporting`, etc.)
  - **MySQL**: Schemas = Databases (when you connect to MySQL, you can access multiple databases)
  - **SQLite**: Schema-less (visibility rules don't apply)

  See the [Visibility Guide](guides/visibility.html) for detailed configuration examples.

  ## Optional Configuration

      config :lotus,
        default_source: "primary",     # Default data source for queries
        unique_names: false,           # Defaults to true
        read_only: false               # Defaults to true; set to false to allow writes
  """

  @type t :: %{
          storage_repo: module(),
          read_only: boolean(),
          unique_names: boolean(),
          data_sources: %{String.t() => module() | map()},
          default_source: String.t() | nil,
          default_page_size: pos_integer() | nil,
          table_visibility: map(),
          column_visibility: map(),
          schema_visibility: map(),
          cache: cache_config()
        }

  @type cache_config :: %{
          optional(:cachex_opts) => keyword(),
          adapter: module() | nil,
          namespace: String.t(),
          profiles: %{atom() => keyword()},
          compress: boolean(),
          max_bytes: non_neg_integer(),
          lock_timeout: non_neg_integer(),
          default_ttl_ms: non_neg_integer(),
          default_profile: atom(),
          key_builder: module()
        }

  @schema [
    storage_repo: [
      type: :atom,
      required: true,
      doc: "The Ecto repository where Lotus will store its query definitions."
    ],
    read_only: [
      type: :boolean,
      default: true,
      doc:
        "When true (default), blocks write operations (INSERT, UPDATE, DELETE, DDL) at the application level. Set to false to allow write queries."
    ],
    allow_unrestricted_resources: [
      type: :boolean,
      default: false,
      doc: """
      Global opt-in for adapters that return `{:unrestricted, _}` from
      `extract_accessed_resources/2`. When `false` (default), preflight blocks
      such statements with an error. When `true`, Lotus trusts the adapter
      (or its engine's own access control layer) to enforce visibility —
      useful for non-SQL adapters like Elasticsearch that gate access at
      the index level. A per-source opt-in via `allow_unrestricted_resources: true`
      in a `data_sources` entry's config map overrides this flag for that
      source only.
      """
    ],
    data_sources: [
      type: {:map, :string, {:or, [:atom, :map]}},
      default: %{},
      doc:
        "Named data sources for query execution. Values are repo modules (Ecto) or config maps (non-Ecto adapters)."
    ],
    default_source: [
      type: :string,
      required: false,
      doc:
        "The default data source name to use when no source is specified. Required when multiple data_sources are configured."
    ],
    default_page_size: [
      type: {:or, [:pos_integer, nil]},
      default: nil,
      doc:
        "Global default page size for windowed pagination when no explicit limit is provided. If not set, falls back to built-in default."
    ],
    unique_names: [
      type: :boolean,
      default: true,
      doc: "Whether to enforce unique query names. Defaults to true."
    ],
    table_visibility: [
      type: :map,
      default: %{},
      doc:
        "Configuration for table visibility rules. Controls which tables are accessible through Lotus queries and discovery."
    ],
    column_visibility: [
      type: :map,
      default: %{},
      doc: """
      Column-level visibility rules. Lets you hide or mask specific columns per table.

      Format: %{repo_key | :default => [rules...]}

      Each rule can be specified using flexible patterns:
      - {schema_pattern | "*" | nil | ~r/.../, table_pattern | "*" | ~r/.../, column_pattern | ~r/.../ | String.t(), policy}
      - {table_pattern | "*" | ~r/.../, column_pattern | ~r/.../ | String.t(), policy} (any schema)
      - {column_pattern | String.t() | ~r/.../, policy} (any schema/table)

      Policy options:
      - Simple atoms: :allow, :omit, :error, :mask (with :null strategy)
      - Keyword list: [action: :mask, mask: :sha256, show_in_schema?: false]
      - Builder functions: Policy.column_mask(:sha256), Policy.column_omit()

      Actions: :allow (show normally), :omit (remove from results), :mask (transform values), :error (fail query)
      Mask strategies: :null, :sha256, {:fixed, value}, {:partial, [keep_last: 4, replacement: "*"]}
      Options: show_in_schema? (default true) — whether column appears in schema introspection

      See Lotus.Visibility.Policy for builder functions and examples.
      """
    ],
    schema_visibility: [
      type: :map,
      default: %{},
      doc: """
      Configuration for schema visibility rules. Controls which schemas are accessible through Lotus.
      Schema rules take precedence over table rules - if a schema is denied, all tables within it are blocked.

      Format: %{repo_key => [allow: [...], deny: [...]], default: [...]}

      Rules support strings, regexes, and :all for allow rules. In MySQL, schemas = databases.
      """
    ],
    cache: [
      type: {:or, [:map, nil]},
      default: nil,
      doc: "Cache configuration including adapter, profiles, and settings."
    ],
    ai: [
      type: :keyword_list,
      default: [],
      doc: """
      AI-powered query generation configuration.

      ## Options

      - `:enabled` (boolean) - Enable AI features. Default: false
      - `:model` (string) - ReqLLM model string, e.g. "openai:gpt-4o", "anthropic:claude-opus-4". Default: "openai:gpt-4o"
      - `:api_key` (string or tuple) - API key or {:system, "ENV_VAR"}

      ## Example

          config :lotus,
            ai: [
              enabled: true,
              model: "openai:gpt-4o",
              api_key: {:system, "OPENAI_API_KEY"}
            ]
      """
    ],
    source_adapters: [
      type: {:list, {:custom, __MODULE__, :validate_source_adapter, []}},
      default: [],
      doc:
        "List of external adapter modules implementing `Lotus.Source.Adapter` with `can_handle?/1` and `wrap/2`."
    ],
    trusted_source_adapters: [
      type: {:list, :atom},
      default: [],
      doc: """
      Adapter modules whose `ai_context/1` output Lotus plumbs through
      to the LLM prompt unchanged. The built-in `Lotus.Source.Adapters.Ecto`
      (and its per-dialect wrappers) are always trusted; listing a
      module here trusts an external adapter the same way.

      For untrusted adapters, only `:language` reaches the prompt;
      `:syntax_notes` and `:error_patterns` are discarded to bound the
      prompt-injection blast radius.
      """
    ],
    source_resolver: [
      type: :atom,
      default: Lotus.Source.Resolvers.Static,
      doc:
        "Module implementing `Lotus.Source.Resolver` behaviour. Resolves named data sources to adapter structs."
    ],
    visibility_resolver: [
      type: :atom,
      default: Lotus.Visibility.Resolvers.Static,
      doc:
        "Module implementing `Lotus.Visibility.Resolver` behaviour. Resolves visibility rules for data sources."
    ],
    middleware: [
      type: {:or, [:map, nil]},
      default: nil,
      doc: """
      Middleware pipeline configuration for query execution and schema discovery hooks.

      Format: %{event => [{Module, opts}]}

      Events: :before_query, :after_query, :after_list_schemas, :after_list_tables,
      :after_describe_table, :after_list_relations, :after_discover

      ## Example

          config :lotus,
            middleware: %{
              before_query: [{MyApp.AuditPlug, []}],
              after_query: [{MyApp.AuditPlug, []}],
              after_list_tables: [{MyApp.TableFilterPlug, []}]
            }
      """
    ]
  ]

  @persistent_term_key {__MODULE__, :validated}

  @doc """
  Loads and validates the Lotus configuration.

  When called with no arguments, returns a cached, pre-validated configuration
  from `:persistent_term`, validating and caching it on first access. When
  called with an explicit keyword list, always validates the supplied options
  without touching the cache.

  Raises `ArgumentError` if the configuration is invalid.
  """
  @spec load!() :: t() | keyword()
  def load! do
    case :persistent_term.get(@persistent_term_key, :__lotus_unset__) do
      :__lotus_unset__ ->
        conf = validate!(get_lotus_config())
        :persistent_term.put(@persistent_term_key, conf)
        conf

      conf ->
        conf
    end
  end

  @spec load!(keyword()) :: t() | keyword()
  def load!(opts), do: validate!(opts)

  @doc """
  Re-reads configuration from the application environment, validates it, and
  refreshes the cached value in `:persistent_term`.

  Call this whenever `:lotus` application environment changes after boot
  (e.g. in tests that use `Application.put_env/3`).
  """
  @spec reload!() :: t() | keyword()
  def reload! do
    conf = validate!(get_lotus_config())
    :persistent_term.put(@persistent_term_key, conf)
    conf
  end

  defp validate!(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, conf} -> validate_default_source!(conf)
      {:error, e} -> raise ArgumentError, "Invalid :lotus config: #{Exception.message(e)}"
    end
  end

  # Cross-validation NimbleOptions can't express: :default_source must be a
  # key in :data_sources when both are set. Catches typos at boot instead of
  # on first query.
  defp validate_default_source!(conf) do
    default = conf[:default_source]
    sources = conf[:data_sources] || %{}

    cond do
      is_nil(default) ->
        conf

      Map.has_key?(sources, default) ->
        conf

      true ->
        raise ArgumentError,
              "Invalid :lotus config: :default_source #{inspect(default)} is not a key " <>
                "in :data_sources. Configured sources: #{inspect(Map.keys(sources))}"
    end
  end

  @doc false
  # NimbleOptions :custom validator for :source_adapters entries.
  # Surfaces typos, unloaded modules, and non-adapter modules at boot rather
  # than at first query (where the resolver would raise UndefinedFunctionError
  # calling can_handle?/1).
  @spec validate_source_adapter(term()) :: {:ok, module()} | {:error, String.t()}
  def validate_source_adapter(mod) when is_atom(mod) and not is_nil(mod) do
    cond do
      not Code.ensure_loaded?(mod) ->
        {:error,
         "expected a loaded module implementing Lotus.Source.Adapter, got: #{inspect(mod)}"}

      not implements_source_adapter?(mod) ->
        {:error, "#{inspect(mod)} does not implement the Lotus.Source.Adapter behaviour"}

      true ->
        {:ok, mod}
    end
  end

  def validate_source_adapter(other) do
    {:error, "expected a module atom, got: #{inspect(other)}"}
  end

  defp implements_source_adapter?(mod) do
    behaviours =
      mod.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Lotus.Source.Adapter in behaviours
  end

  defp get_lotus_config do
    Application.get_all_env(:lotus)
    |> Keyword.take([
      :storage_repo,
      :read_only,
      :allow_unrestricted_resources,
      :unique_names,
      :data_sources,
      :default_source,
      :default_page_size,
      :table_visibility,
      :column_visibility,
      :schema_visibility,
      :cache,
      :ai,
      :source_adapters,
      :trusted_source_adapters,
      :source_resolver,
      :visibility_resolver,
      :middleware
    ])
  end

  @doc """
  Returns the configured Ecto repository.
  """
  @spec repo!() :: module()
  def repo!, do: load!()[:storage_repo]

  @doc """
  Returns whether unique query names are enforced.
  """
  @spec unique_names?() :: boolean()
  def unique_names?, do: load!()[:unique_names]

  @doc """
  Returns whether queries are restricted to read-only operations.
  """
  @spec read_only?() :: boolean()
  def read_only?, do: load!()[:read_only]

  @doc """
  Returns whether the given source is allowed to return
  `{:unrestricted, _}` from `extract_accessed_resources/2` without being
  blocked by preflight.

  Resolution order:

    1. If the source's `data_sources` entry is a config map and has
       `allow_unrestricted_resources: true`, returns `true` for that
       source regardless of the global flag.
    2. Falls back to the top-level `:allow_unrestricted_resources` flag.

  Used by `Lotus.Preflight.authorize/3` to gate non-SQL adapters whose
  engines enforce visibility at a layer Lotus can't introspect.
  """
  @spec allow_unrestricted_resources?(String.t()) :: boolean()
  def allow_unrestricted_resources?(name) when is_binary(name) do
    case Map.get(data_sources(), name) do
      %{allow_unrestricted_resources: true} -> true
      _ -> load!()[:allow_unrestricted_resources]
    end
  end

  @doc """
  Returns the configured data sources.
  """
  @spec data_sources() :: %{String.t() => module() | map()}
  def data_sources, do: load!()[:data_sources]

  @doc """
  Gets a data source by name.

  Returns the source module or raises if not found.
  """
  @spec get_data_source!(String.t()) :: module() | map()
  def get_data_source!(name) do
    case Map.get(data_sources(), name) do
      nil ->
        raise ArgumentError,
              "Data source #{inspect(name)} not configured. " <>
                "Available sources: #{inspect(Map.keys(data_sources()))}"

      source ->
        source
    end
  end

  @doc """
  Lists the names of all configured data sources.
  """
  @spec list_data_source_names() :: [String.t()]
  def list_data_source_names, do: Map.keys(data_sources())

  @doc """
  Returns the default data source as a {name, module} tuple.

  - If default_source is configured, returns that source
  - If default_source is not configured, returns the first available source
  - If no data sources are configured, raises an error
  """
  @spec default_data_source() :: {String.t(), module()}
  def default_data_source do
    sources = data_sources()

    case :maps.size(sources) do
      0 ->
        raise ArgumentError, """
        No data source available for query execution.

        Please configure at least one data source:

            config :lotus,
              data_sources: %{
                "primary" => MyApp.Repo
              }
        """

      _ ->
        case load!()[:default_source] do
          nil ->
            Enum.at(sources, 0)

          default_name ->
            {default_name, get_data_source!(default_name)}
        end
    end
  end

  @doc """
  Returns table visibility rules for a specific source.

  Falls back to default rules if source-specific rules are not configured.
  """
  @spec rules_for_source_name(String.t()) :: keyword()
  def rules_for_source_name(source_name),
    do: visibility_rules_for(:table_visibility, source_name)

  @doc """
  Returns schema visibility rules for a specific source.

  Falls back to default rules if source-specific rules are not configured.
  """
  @spec schema_rules_for_source_name(String.t()) :: keyword()
  def schema_rules_for_source_name(source_name),
    do: visibility_rules_for(:schema_visibility, source_name)

  @doc """
  Returns column visibility rules for a specific source.

  Falls back to default rules if source-specific rules are not configured.
  """
  @spec column_rules_for_source_name(String.t()) :: list()
  def column_rules_for_source_name(source_name),
    do: visibility_rules_for(:column_visibility, source_name)

  # Shared lookup for source-keyed visibility maps. Matches the source name
  # string against map keys via `to_string/1`, then falls back to the
  # `:default` entry, then to an empty list.
  defp visibility_rules_for(key, source_name) do
    visibility_config = load!()[key] || %{}
    source_key = Enum.find(Map.keys(visibility_config), &(to_string(&1) == source_name))

    (source_key && visibility_config[source_key]) || visibility_config[:default] || []
  end

  @doc """
  Gets a configuration value by key.

  Returns the configuration for the given key from the application environment.
  """
  @spec get(atom()) :: any()
  def get(key) do
    load!()[key]
  end

  @doc """
  Returns the cache configuration.
  """
  @spec cache_config() :: cache_config() | nil
  def cache_config, do: load!()[:cache]

  @doc """
  Returns cache settings for a specific profile.

  Falls back to built-in defaults for :results, :schema, and :options profiles.
  Users can override these defaults in their configuration.
  """
  @spec cache_profile_settings(atom()) :: keyword()
  def cache_profile_settings(profile_name) do
    case cache_config() do
      nil -> default_profile_settings(profile_name)
      config -> configured_profile_settings(profile_name, config)
    end
  end

  defp default_profile_settings(:results), do: [ttl_ms: :timer.seconds(60)]
  defp default_profile_settings(:schema), do: [ttl_ms: :timer.hours(1)]
  defp default_profile_settings(:options), do: [ttl_ms: :timer.minutes(5)]
  defp default_profile_settings(_), do: []

  defp configured_profile_settings(profile_name, config) do
    profiles = config[:profiles] || %{}
    profiles[profile_name] || fallback_profile_settings(profile_name, config)
  end

  defp fallback_profile_settings(:results, config) do
    [ttl_ms: config[:default_ttl_ms] || :timer.seconds(60)]
  end

  defp fallback_profile_settings(:schema, _config), do: [ttl_ms: :timer.hours(1)]
  defp fallback_profile_settings(:options, _config), do: [ttl_ms: :timer.minutes(5)]
  defp fallback_profile_settings(_, _config), do: []

  @doc """
  Returns cache adapter module if configured.
  """
  @spec cache_adapter() :: {:ok, module()} | :error
  def cache_adapter do
    case cache_config() do
      nil ->
        :error

      config ->
        case config[:adapter] do
          nil -> :error
          mod when is_atom(mod) -> {:ok, mod}
        end
    end
  end

  @doc """
  Returns the configured cache key builder module.

  Falls back to `Lotus.Cache.KeyBuilder.Default` when not configured.
  """
  @spec cache_key_builder() :: module()
  def cache_key_builder do
    case cache_config() do
      nil -> Lotus.Cache.KeyBuilder.Default
      config -> config[:key_builder] || Lotus.Cache.KeyBuilder.Default
    end
  end

  @doc """
  Returns the cache namespace.
  """
  @spec cache_namespace() :: String.t()
  def cache_namespace do
    (cache_config() || [])[:namespace] || "lotus:v1"
  end

  @doc """
  Returns the globally configured default cache profile.

  Falls back to :results if none configured.
  """
  @spec default_cache_profile() :: atom()
  def default_cache_profile do
    case cache_config() do
      nil -> :results
      config -> config[:default_profile] || :results
    end
  end

  @doc """
  Returns the globally configured default page size for windowed pagination, if any.

  When nil, Lotus uses its built-in default page size.
  """
  @spec default_page_size() :: pos_integer() | nil
  def default_page_size, do: load!()[:default_page_size]

  @doc """
  Returns middleware configuration map, or empty map if not configured.
  """
  @spec middleware() :: map()
  def middleware, do: get(:middleware) || %{}

  @doc """
  Returns AI configuration keyword list.
  """
  @spec ai() :: keyword()
  def ai, do: get(:ai) || []

  @doc """
  Returns whether AI features are enabled.
  """
  @spec ai_enabled?() :: boolean()
  def ai_enabled?, do: (get(:ai) || [])[:enabled] || false

  @doc """
  Returns the list of external source adapter modules.
  """
  @spec source_adapters() :: [module()]
  def source_adapters, do: load!()[:source_adapters]

  @doc """
  Return whether the given adapter module is trusted to contribute
  free-form text (`:syntax_notes`, `:error_patterns`) to AI prompts.

  Always-trusted: the built-in `Lotus.Source.Adapters.Ecto` and the
  first-party per-dialect adapters it exposes via `builtin_adapters/0`
  (Postgres, MySQL, SQLite3). Additional modules can be trusted via
  `config :lotus, :trusted_source_adapters, [MyAdapter]`.

  Untrusted adapters still supply a `:language` identifier to the
  prompt — just not the free-form fields.
  """
  @spec trusted_source_adapter?(module()) :: boolean()
  def trusted_source_adapter?(mod) when is_atom(mod) do
    alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

    mod == EctoAdapter or
      mod in EctoAdapter.builtin_adapters() or
      mod in load!()[:trusted_source_adapters]
  end

  @doc """
  Returns the configured source resolver module.
  """
  @spec source_resolver() :: module()
  def source_resolver, do: load!()[:source_resolver]

  @doc """
  Returns the configured visibility resolver module.
  """
  @spec visibility_resolver() :: module()
  def visibility_resolver, do: load!()[:visibility_resolver]

  @doc """
  Returns the entire validated configuration as a map.

  Useful for debugging or inspection.
  """
  @spec all() :: t() | keyword()
  def all, do: load!()
end
