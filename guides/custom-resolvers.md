# Custom Resolvers

Lotus exposes two supported extension points that let you replace how sources and visibility rules are loaded at runtime:

- `Lotus.Source.Resolver` — turns source names (or modules) into `%Lotus.Source.Adapter{}` structs.
- `Lotus.Visibility.Resolver` — loads schema, table, and column visibility rules for a given source.

Both are small, stable behaviours. Lotus ships with default static implementations (`Lotus.Source.Resolvers.Static` and `Lotus.Visibility.Resolvers.Static`) that read from application configuration — which is all most applications need. When you need runtime dynamism, custom resolvers let you source this data from anywhere without forking Lotus.

## When to Use a Custom Resolver

The default static resolvers read application configuration, which `Lotus.Config` validates once and caches in `:persistent_term`. That's ideal for applications whose sources and rules never change after boot. Consider a custom resolver when any of the following apply:

### Custom `Source.Resolver`

- Sources are registered at runtime (not via `config :lotus, data_sources: ...`).
- Data sources live in a database, registry service, or admin UI.
- Per-tenant sources must be added or removed without restarts.
- Each environment (dev/staging/prod) needs a different resolution strategy.
- You want to compose adapters dynamically (e.g. pick a replica based on health).

### Custom `Visibility.Resolver`

- Visibility rules must change without application restarts.
- Rules are stored in a database, remote service, or feature flag system.
- Different tenants, roles, or environments need different rules.
- Column masking policies are driven by application state (e.g. "admin" vs "analyst").

If neither list applies to your application, stick with the defaults.

## Configuration

Both resolvers are configured in application config and default to the static implementations:

```elixir
config :lotus,
  # Default: Lotus.Source.Resolvers.Static
  source_resolver: MyApp.SourceResolver,

  # Default: Lotus.Visibility.Resolvers.Static
  visibility_resolver: MyApp.VisibilityResolver
```

When omitted, the defaults read from `:data_sources`, `:schema_visibility`, `:table_visibility`, and `:column_visibility` — the same behaviour Lotus has always had.

> ### Note {: .info}
>
> `Lotus.Config` caches the resolved configuration in `:persistent_term` at application boot. If you change `:source_resolver` or `:visibility_resolver` at runtime (e.g. in tests), call `Lotus.Config.reload!/0` to refresh the cache.

## The `Source.Resolver` Behaviour

A source resolver turns query options (`source_opt`, `fallback`) into `%Lotus.Source.Adapter{}` structs. It also enumerates available sources for schema discovery and admin tooling.

### Callbacks

```elixir
@callback resolve(
            source_opt :: nil | String.t() | module(),
            fallback :: nil | String.t() | module()
          ) :: {:ok, Lotus.Source.Adapter.t()} | {:error, term()}

@callback list_sources() :: [Lotus.Source.Adapter.t()]

@callback get_source!(name :: String.t()) :: Lotus.Source.Adapter.t() | no_return()

@callback list_source_names() :: [String.t()]

@callback default_source() :: {String.t(), Lotus.Source.Adapter.t()}
```

| Callback | Returns | Used By |
|---|---|---|
| `resolve/2` | `{:ok, %Adapter{}}` or `{:error, :not_found}` | Query execution (`Lotus.run_statement/3`, `Lotus.run_query/2`) |
| `list_sources/0` | `[%Adapter{}]` | Schema discovery, admin UIs |
| `get_source!/1` | `%Adapter{}` (raises on missing) | Ad-hoc lookups |
| `list_source_names/0` | `[String.t()]` | Error messages, admin UIs |
| `default_source/0` | `{name, %Adapter{}}` | Fallback when no repo is specified |

> ### Return `{:error, :not_found}` on failure {: .warning}
>
> `Lotus.Source.resolve!/2` matches exactly two shapes: `{:ok, %Adapter{}}` and `{:error, :not_found}` — the latter becomes an `ArgumentError` naming the configured sources (from your `list_source_names/0`). Any other error tuple raises a `CaseClauseError` instead of that message.

### Resolution Priority

The default resolver (`Lotus.Source.Resolvers.Static`) follows this priority inside `resolve/2`:

1. `source_opt` as string name — lookup in `data_sources`, wrap in adapter
2. `source_opt` as module — reverse lookup (find name for module), wrap in adapter
3. `fallback` as string name — lookup
4. `fallback` as module — reverse lookup
5. Both `nil` — use the configured `default_source`
6. Otherwise — `{:error, :not_found}`

Note step 6: when either position named something that could not be resolved, the static resolver refuses rather than falling back to the default source. A typo in a saved query's `data_source` would otherwise quietly return rows from a different database. Custom implementations are free to adopt a different priority, but should keep that property and accept the same arguments so the public API (`Lotus.run_statement/3`, `Lotus.run_query/2`, etc.) continues to work without changes.

### Building the `%Adapter{}`

Whatever your resolver's lookup strategy, the struct it returns is built by an adapter module's `wrap/2`:

- `Lotus.Source.Adapters.Ecto.wrap/2` for an `Ecto.Repo` module — it picks the right per-dialect adapter (`Adapters.Postgres`, `MySQL`, `SQLite3`) from the repo's Ecto adapter.
- Your own adapter's `wrap/2` for a non-Ecto source, e.g. `MyApp.Adapters.Elasticsearch.wrap("search", %{url: "http://localhost:9200"})`.

See the [Source Adapters guide](source-adapters.md) for the adapter contract itself.

### Example: Agent-backed `Source.Resolver`

The following resolver loads adapters from an `Agent` so you can mutate the registered set at runtime. It wraps each registered `Ecto.Repo` with `Lotus.Source.Adapters.Ecto.wrap/2`, so everything downstream — SQL generation, execution, introspection — works exactly as it does with the static resolver.

```elixir
defmodule MyApp.AgentSourceResolver do
  @moduledoc """
  A runtime-mutable source resolver backed by an Agent.

  Register and remove sources with `put/2` and `delete/1`. All registered
  sources are wrapped via `Lotus.Source.Adapters.Ecto.wrap/2`.
  """

  use Agent

  @behaviour Lotus.Source.Resolver

  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  # ---------------------------------------------------------------------------
  # Agent API
  # ---------------------------------------------------------------------------

  def start_link(initial_sources \\ %{}) when is_map(initial_sources) do
    Agent.start_link(fn -> initial_sources end, name: __MODULE__)
  end

  def put(name, repo_module) when is_binary(name) and is_atom(repo_module) do
    Agent.update(__MODULE__, &Map.put(&1, name, repo_module))
  end

  def delete(name) when is_binary(name) do
    Agent.update(__MODULE__, &Map.delete(&1, name))
  end

  defp sources, do: Agent.get(__MODULE__, & &1)

  # ---------------------------------------------------------------------------
  # Lotus.Source.Resolver callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def resolve(source_opt, fallback) do
    cond do
      is_binary(source_opt) -> lookup_by_name(source_opt)
      repo_module?(source_opt) -> lookup_by_module(source_opt)
      is_binary(fallback) -> lookup_by_name(fallback)
      repo_module?(fallback) -> lookup_by_module(fallback)
      is_nil(source_opt) and is_nil(fallback) -> default_or_error()
      true -> {:error, :not_found}
    end
  end

  @impl true
  def list_sources do
    Enum.map(sources(), fn {name, mod} -> EctoAdapter.wrap(name, mod) end)
  end

  @impl true
  def get_source!(name) do
    case Map.fetch(sources(), name) do
      {:ok, mod} ->
        EctoAdapter.wrap(name, mod)

      :error ->
        raise ArgumentError,
              "Source '#{name}' not registered. Available: #{inspect(Map.keys(sources()))}"
    end
  end

  @impl true
  def list_source_names, do: Map.keys(sources())

  @impl true
  def default_source do
    case Enum.at(sources(), 0) do
      {name, mod} -> {name, EctoAdapter.wrap(name, mod)}
      nil -> raise "No sources registered in #{inspect(__MODULE__)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup_by_name(name) do
    case Map.fetch(sources(), name) do
      {:ok, mod} -> {:ok, EctoAdapter.wrap(name, mod)}
      :error -> {:error, :not_found}
    end
  end

  defp lookup_by_module(mod) do
    case Enum.find(sources(), fn {_n, m} -> m == mod end) do
      {name, _} -> {:ok, EctoAdapter.wrap(name, mod)}
      nil -> {:error, :not_found}
    end
  end

  defp default_or_error do
    case Enum.at(sources(), 0) do
      {name, mod} -> {:ok, EctoAdapter.wrap(name, mod)}
      nil -> {:error, :not_found}
    end
  end

  defp repo_module?(mod) when is_atom(mod) and not is_nil(mod),
    do: function_exported?(mod, :__adapter__, 0)

  defp repo_module?(_), do: false
end
```

Start the `Agent` in your supervision tree and wire it up:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {MyApp.AgentSourceResolver, %{"main" => MyApp.Repo}},
    # ... rest of your supervision tree
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

```elixir
# config/config.exs
config :lotus,
  source_resolver: MyApp.AgentSourceResolver
```

Now you can register sources at runtime:

```elixir
MyApp.AgentSourceResolver.put("warehouse", MyApp.WarehouseRepo)

Lotus.run_statement("SELECT COUNT(*) FROM orders", [], repo: "warehouse")
```

## The `Visibility.Resolver` Behaviour

A visibility resolver returns the schema, table, and column rules that Lotus applies when filtering schemas and tables, or when masking/omitting columns.

### Callbacks

```elixir
@callback schema_rules_for(source_name :: String.t(), scope :: term()) :: keyword()
@callback table_rules_for(source_name :: String.t(), scope :: term()) :: keyword()
@callback column_rules_for(source_name :: String.t(), scope :: term()) :: list()
```

| Callback | Returns | Example shape |
|---|---|---|
| `schema_rules_for/2` | `keyword()` | `[allow: ["public"], deny: ["legacy"]]` |
| `table_rules_for/2` | `keyword()` | `[allow: [{"public", ~r/^dim_/}], deny: ["api_keys"]]` |
| `column_rules_for/2` | `list()` | `[{"public", "users", "ssn", :mask}]` |

The rule formats are exactly the same as those consumed by the default static resolver — see the [Visibility Guide](visibility.md) for the full syntax.

Each callback is invoked with the source name (a string) and an opaque `scope` term so you can return different rules for different sources and scopes. The scope is `nil` when the caller doesn't pass one. Return an empty list or empty keyword list when no rules apply — Lotus treats missing allow lists as "allow all" and missing deny lists as "deny nothing".

The `scope` value is also hashed into the discovery cache key, so different scopes produce independent cached entries. Keep scope low-cardinality for good cache hit rates — per-role or per-tenant is fine; per-request is not.

### Example: ETS-backed `Visibility.Resolver` with Hot Reload

This resolver reads rules from a named ETS table so updates propagate immediately without restarts. ETS gives you concurrent reads from the Lotus hot path without any coordination overhead.

```elixir
defmodule MyApp.EtsVisibilityResolver do
  @moduledoc """
  A visibility resolver that reads rules from a named ETS table.

  Call `init/0` once at application boot, then update rules at runtime
  with `put_rules/2`. Subsequent Lotus calls see the new rules immediately.
  """

  @behaviour Lotus.Visibility.Resolver

  @table :my_app_lotus_visibility_rules

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc "Create the ETS table. Call once at application boot."
  def init do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ok
  end

  @doc """
  Replace (or merge) rules for a given source.

  Accepts a keyword list with `:schema_rules`, `:table_rules`, and
  `:column_rules`. Any omitted key is left unchanged.
  """
  def put_rules(source_name, opts) when is_binary(source_name) do
    existing = lookup(source_name)

    merged =
      Keyword.merge(
        existing,
        Keyword.take(opts, [:schema_rules, :table_rules, :column_rules])
      )

    :ets.insert(@table, {source_name, merged})
    :ok
  end

  @doc "Clear all rules for a source."
  def delete_rules(source_name) when is_binary(source_name) do
    :ets.delete(@table, source_name)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Lotus.Visibility.Resolver callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def schema_rules_for(source_name, _scope),
    do: Keyword.get(lookup(source_name), :schema_rules, [])

  @impl true
  def table_rules_for(source_name, _scope),
    do: Keyword.get(lookup(source_name), :table_rules, [])

  @impl true
  def column_rules_for(source_name, _scope),
    do: Keyword.get(lookup(source_name), :column_rules, [])

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup(source_name) do
    case :ets.lookup(@table, source_name) do
      [{^source_name, rules}] -> rules
      [] -> []
    end
  end
end
```

Initialize the table from your application's `start/2` callback and wire up the resolver:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  MyApp.EtsVisibilityResolver.init()
  # ... rest of your supervision tree
end
```

```elixir
# config/config.exs
config :lotus,
  visibility_resolver: MyApp.EtsVisibilityResolver
```

Update rules at runtime — subsequent Lotus calls immediately see the new values:

```elixir
MyApp.EtsVisibilityResolver.put_rules("main",
  schema_rules: [allow: ["public", ~r/^tenant_/], deny: ["legacy"]],
  table_rules: [deny: ["api_keys", "user_passwords"]],
  column_rules: [
    {"public", "users", "ssn", [action: :mask, mask: :sha256]}
  ]
)
```

### Example: Scope-Aware Visibility Resolver

A resolver can use the `scope` argument to return different rules for different contexts. The caller passes `:scope` to discovery functions; Lotus forwards it to the resolver and hashes it into the cache key.

```elixir
defmodule MyApp.ScopedVisibilityResolver do
  @behaviour Lotus.Visibility.Resolver

  @impl true
  def schema_rules_for(source_name, scope) do
    case scope do
      %{role: :admin} -> []  # admins see all schemas
      _ -> MyApp.Store.schema_rules(source_name, scope)
    end
  end

  @impl true
  def table_rules_for(source_name, scope) do
    MyApp.Store.table_rules(source_name, scope)
  end

  @impl true
  def column_rules_for(source_name, scope) do
    MyApp.Store.column_rules(source_name, scope)
  end
end
```

Callers pass scope via opts:

```elixir
# Admins see everything
Lotus.list_tables("postgres", scope: %{role: :admin})

# Regular users get filtered results (cached separately from admins)
Lotus.list_tables("postgres", scope: %{role: :viewer, tenant: "acme"})

# No scope — identical to pre-scope behavior
Lotus.list_tables("postgres")
```

> **Cache cardinality warning:** Each unique scope value produces a separate cache entry. Keep scopes low-cardinality (per-role, per-tenant) for good hit rates. Per-request or per-user scopes will fill the cache with one-off entries.

## Testing Custom Resolvers

Both behaviours are small, so your resolvers are easy to test directly with plain ExUnit. Cover two levels:

### Unit Tests

Call your resolver module directly and assert on the return values:

```elixir
defmodule MyApp.AgentSourceResolverTest do
  use ExUnit.Case

  alias Lotus.Source.Adapter
  alias MyApp.AgentSourceResolver

  setup do
    start_supervised!({AgentSourceResolver, %{"main" => MyApp.Repo}})
    :ok
  end

  test "resolves a registered source by name" do
    assert {:ok, %Adapter{name: "main", state: MyApp.Repo}} =
             AgentSourceResolver.resolve("main", nil)
  end

  test "returns :not_found for unknown sources" do
    assert {:error, :not_found} = AgentSourceResolver.resolve("missing", nil)
  end

  test "list_sources/0 returns every registered source" do
    AgentSourceResolver.put("warehouse", MyApp.WarehouseRepo)

    names =
      AgentSourceResolver.list_sources()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == ["main", "warehouse"]
  end
end
```

Visibility resolvers test the same way:

```elixir
defmodule MyApp.EtsVisibilityResolverTest do
  use ExUnit.Case

  alias MyApp.EtsVisibilityResolver

  setup do
    if :ets.info(:my_app_lotus_visibility_rules) == :undefined do
      EtsVisibilityResolver.init()
    end

    on_exit(fn -> EtsVisibilityResolver.delete_rules("main") end)
    :ok
  end

  test "returns stored schema rules" do
    EtsVisibilityResolver.put_rules("main",
      schema_rules: [allow: ["public"], deny: ["legacy"]]
    )

    assert EtsVisibilityResolver.schema_rules_for("main", nil) ==
             [allow: ["public"], deny: ["legacy"]]
  end

  test "returns an empty list when a source has no rules" do
    assert EtsVisibilityResolver.schema_rules_for("unknown", nil) == []
    assert EtsVisibilityResolver.table_rules_for("unknown", nil) == []
    assert EtsVisibilityResolver.column_rules_for("unknown", nil) == []
  end
end
```

### Integration Tests

Configure Lotus to use your resolver and exercise the public API (`Lotus.run_statement/3`, `Lotus.list_tables/2`, etc.). A common pattern is to toggle the resolver per-test with `Application.put_env/3` and call `Lotus.Config.reload!/0` so the new value is picked up immediately:

```elixir
setup do
  original = Application.get_env(:lotus, :source_resolver)
  Application.put_env(:lotus, :source_resolver, MyApp.AgentSourceResolver)
  Lotus.Config.reload!()

  on_exit(fn ->
    if original do
      Application.put_env(:lotus, :source_resolver, original)
    else
      Application.delete_env(:lotus, :source_resolver)
    end

    Lotus.Config.reload!()
  end)

  :ok
end

test "Lotus.run_statement/3 uses the configured resolver" do
  MyApp.AgentSourceResolver.put("main", MyApp.Repo)

  assert {:ok, _result} = Lotus.run_statement("SELECT 1", [], repo: "main")
end
```

The same pattern works for visibility resolvers — swap `:source_resolver` for `:visibility_resolver` and assert on the results of `Lotus.list_schemas/2`, `Lotus.list_tables/2`, or individual `Lotus.Visibility` checks.

## Guidelines

- **Keep resolvers stateless where possible.** If you need state, store it in a supervised process (`Agent`, `GenServer`, ETS) so it survives across queries.
- **Return quickly.** Resolvers run on the query hot path — expensive work like database lookups should be cached or moved to a cache-friendly store like ETS or `:persistent_term`.
- **Preserve resolver contracts.** The defaults raise on unconfigured sources via `get_source!/1` and `default_source/0`; follow the same convention so callers do not need to special-case errors per resolver.
- **Reuse the default Ecto adapter where possible.** `Lotus.Source.Adapters.Ecto.wrap/2` turns an `Ecto.Repo` module into an `%Adapter{}` — use it inside your custom resolver instead of hand-rolling a new adapter. Only write a fully custom `Lotus.Source.Adapter` implementation when your source is not backed by Ecto.
- **Remember to call `Lotus.Config.reload!/0` after changing resolvers at runtime.** The validated configuration is cached in `:persistent_term`, so changes to `:source_resolver` or `:visibility_resolver` only take effect after a reload. This is usually only relevant in tests.

## See Also

- [Source Adapters guide](source-adapters.md) — reference for implementing non-Ecto adapters
- [Visibility guide](visibility.md) — the rule format consumed by `Visibility.Resolver` implementations
- [Configuration guide](configuration.md) — full list of configuration keys
