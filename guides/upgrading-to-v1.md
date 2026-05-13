# Upgrading to Lotus v1.0

Lotus v1.0 locks the public API for the v1.x line. This means several v0.x
names that were deprecated through 0.16.x have been removed outright, and a
few internal shapes that leaked SQL assumptions into the universal contract
have been reshaped.

This guide is aimed at **host-app upgraders** (lotus_web, lotus_pro,
lotus_works, or any app embedding Lotus directly). If you are authoring a
custom `Lotus.Source.Adapter`, read the [source adapters
guide](source-adapters.md) in addition — several callback signatures changed.

The full breaking-change list lives in the v1.0.0 entry of the
[CHANGELOG](../CHANGELOG.md). This guide groups changes by what you need to
do in your host app.

---

## 1. Configuration renames

Three config keys were renamed. No deprecation aliases — the old keys raise at
`Lotus.Config` validation.

```diff
 config :lotus,
-  ecto_repo: MyApp.Repo,
+  storage_repo: MyApp.Repo,
-  default_repo: "main",
+  default_source: "main",
-  data_repos: %{
+  data_sources: %{
     "main"      => MyApp.Repo,
     "analytics" => MyApp.AnalyticsRepo
   }
```

The accessor names (`Lotus.repo/0`, `Lotus.Config.repo!/0`) did not change.
Only the config keys moved.

---

## 2. Public API — removed functions

The following 0.16.x deprecated helpers were removed:

| Removed | Replacement |
|---|---|
| `Lotus.data_repos/0` | `Lotus.Source.list_sources/0` (returns `[%Adapter{}]`) |
| `Lotus.get_data_repo!/1` | `Lotus.Source.get_source!/1` (returns `%Adapter{}`) |
| `Lotus.list_data_repo_names/0` | `Lotus.list_data_source_names/0` |
| `Lotus.default_data_repo/0` | `Lotus.Source.default_source/0` |
| `Lotus.run_sql/3` | `Lotus.run_statement/3` (same signature) |
| `Lotus.Runner.run_sql/4` | `Lotus.Runner.run_statement/3` (see §6 — takes `%Statement{}`) |
| `Lotus.get_table_schema/3` | `Lotus.describe_table/3` |
| `Lotus.Config.data_repos/0`, `get_data_repo!/1`, … | `Lotus.Config.data_sources/0`, `get_data_source!/1`, … |
| `Lotus.Config.rules_for_repo_name/1` (+ schema / column variants) | `Lotus.Config.rules_for_source_name/1` (+ schema / column variants) |
| `Lotus.Config.normalize_deprecated_keys/1` | N/A — deprecated-key normalization removed; validation now fails outright |

If you have a host-app grep for `data_repo`, `run_sql`, or `get_table_schema`
this is your checklist.

---

## 3. DB column rename — `data_repo` → `data_source`

The `lotus_queries` table's `data_repo` column was renamed to `data_source`.
`Lotus.Storage.Query` previously carried a `field(:data_source, :string,
source: :data_repo)` shim; the shim is gone.

### Postgres

A migration module ships with v1.0 — run the migration chain as usual:

```bash
mix ecto.migrate
```

`Lotus.Migrations.Postgres.V4` issues an idempotent
`ALTER TABLE ... RENAME COLUMN data_repo TO data_source` inside a `DO $$` block.
Fresh installs skip it (the column ships with the new name in `V1`).

### MySQL and SQLite

The MySQL and SQLite migrations are single-file (unversioned). Upgraders must
run the rename manually **before** deploying app code:

```sql
-- MySQL
ALTER TABLE lotus_queries RENAME COLUMN data_repo TO data_source;

-- SQLite (3.25+)
ALTER TABLE lotus_queries RENAME COLUMN data_repo TO data_source;
```

Fresh installs land on the correct column name automatically.

---

## 4. Cache tag prefix — `repo:*` → `source:*`

Every discovery and result cache entry Lotus writes is tagged with
`source:<name>` instead of `repo:<name>`.

**What this means for upgraders:**

- Pre-v1 cached entries will miss after the upgrade and get re-seeded on the
  next read. This is not a correctness bug — just a one-time cold-start cost.
- Host middleware that subscribes to cache tags or invalidates by tag must
  update the prefix:

  ```diff
  - Lotus.Cache.invalidate_tags(["repo:main"])
  + Lotus.Cache.invalidate_tags(["source:main"])
  ```

- Custom `Lotus.Cache.KeyBuilder` implementations that build tags for
  cached entries must swap the prefix.

---

## 5. Middleware and telemetry payload changes

Every event that previously carried `:sql` and `:params` as separate top-level
keys now carries a single `:statement` key containing a
`%Lotus.Query.Statement{}` struct.

### Middleware (`:before_query`, `:after_query`)

```diff
 # Before:
-def call(%{sql: sql, params: params} = payload, _opts) do
+def call(%{statement: %Lotus.Query.Statement{text: sql, params: params}} = payload, _opts) do
   ...
 end
```

Also: the `:repo` payload key was renamed to `:source` across every
middleware event. Duplicate `:repo_name` was removed from discovery events.

```diff
- def call(%{repo: repo_name, ...} = payload, _opts) do
+ def call(%{source: source_name, ...} = payload, _opts) do
```

Discovery event `:after_get_table_schema` was renamed to `:after_describe_table`.

### Telemetry (`[:lotus, :query, :start | :stop | :exception]`)

Metadata carries `:statement` (a `%Statement{}`) instead of `:sql`/`:params`.

```diff
 :telemetry.attach("my-query-logger", [:lotus, :query, :stop], fn _event, _measurements, metadata, _ ->
-  Logger.info("ran #{metadata.sql}, #{length(metadata.params)} params")
+  Logger.info("ran #{inspect(metadata.statement.text)}, #{length(metadata.statement.params)} params")
 end, [])
```

For Ecto-backed adapters, `statement.text` is the SQL string and
`statement.params` is the parameter list — the same shape the old keys held.

---

## 6. AI changes

### `Lotus.AI.suggest_optimizations/1` takes `:statement`, not `:sql`

No backward-compat shim — hard rename.

```diff
 Lotus.AI.suggest_optimizations(
-  sql: "SELECT * FROM users",
-  params: [],
+  statement: Lotus.Query.Statement.new("SELECT * FROM users"),
   data_source: "main"
 )
```

### New error shape for disabled AI features

Sources can now declare per-feature AI capabilities via the adapter's
`ai_context/1` callback. When a caller invokes a disabled feature, the return
is a structured tuple instead of a generic error:

```elixir
# New:
{:error, {:ai_feature_unsupported, :optimization, "This source has no execution plan API"}}
```

UIs should gate AI buttons per-source using `Lotus.AI.supports?/2` and
`Lotus.AI.unsupported_reason/2` (both read from the adapter's declared
capabilities). `Lotus.AI.enabled?/0` is a global on/off and no longer
sufficient on its own.

### Internal module renames (visible if you reach into them)

- `Lotus.AI.SQLGenerator` → `Lotus.AI.QueryGenerator`
- `Lotus.AI.Prompts.SQLGeneration` → `Lotus.AI.Prompts.QueryGeneration`
- `Lotus.AI.Actions.GetTableSchema` → `Lotus.AI.Actions.DescribeTable` (also:
  LLM-visible tool name changed from `"get_table_schema"` to
  `"describe_table"`)

Public entry points (`Lotus.AI.generate_query/1`,
`Lotus.AI.generate_query_with_context/1`, `Lotus.AI.explain_query/1`) are
unchanged.

---

## 7. `Lotus.SQL.*` namespace moved under Ecto

Internal SQL-specific modules moved out of the universal code path to make
the adapter contract cleanly non-SQL-aware:

| Old | New |
|---|---|
| `Lotus.SQL.FilterInjector` | `Lotus.Source.Adapters.Ecto.SQL.FilterInjector` |
| `Lotus.SQL.SortInjector` | `Lotus.Source.Adapters.Ecto.SQL.SortInjector` |
| `Lotus.SQL.Transformer` | `Lotus.Source.Adapters.Ecto.SQL.Transformer` |
| `Lotus.SQL.Sanitizer` | `Lotus.Source.Adapters.Ecto.SQL.Sanitizer` |
| `Lotus.SQL.Validator` | `Lotus.Source.Adapters.Ecto.SQL.Validator` |
| `Lotus.SQL.Identifier` | `Lotus.Source.Adapters.Ecto.SQL.Identifier` |

If you were reaching into these directly, two options:

1. Reach through the adapter contract instead —
   `Lotus.Source.Adapter.validate_statement/3`,
   `validate_identifier/3`, `parse_qualified_name/2`,
   `apply_filters/3`, `apply_sorts/3`.
2. Update to the new module paths if you specifically want the Ecto-internal
   helpers.

One elevation in the other direction:
`Lotus.SQL.OptionalClause` → `Lotus.Query.OptionalClause`. The `[[ ... ]]` /
`{{var}}` template syntax is language-agnostic and sits in the universal
query namespace now. Update any references.

---

## 8. Adapter authors: callback contract changes

If you maintain a custom `Lotus.Source.Adapter`, read the [authoring
guide](source-adapters.md) for the full v1.0 contract. Summary of what
changed:

- **`%Lotus.Query.Statement{}` struct** replaces the `(sql, params)` tuple
  that pipeline callbacks passed around. `apply_filters/3`, `apply_sorts/3`,
  `apply_pagination/3`, `transform_bound_query/3`, `transform_statement/2`
  all take and return `%Statement{}`.
- **`substitute_variable/5` + `substitute_list_variable/5`** — new universal
  callbacks. Adapters own their variable-substitution strategy. Non-SQL
  adapters that inline values are the primary injection boundary — see the
  authoring guide's security section.
- **`param_placeholder/4` + `limit_offset_placeholders/3`** removed from
  `Lotus.Source.Adapter`. These were SQL-prepared-statement primitives
  masquerading as universal callbacks. They still exist on
  `Lotus.Source.Adapters.Ecto.Dialect` as Ecto-internal.
- **`extract_accessed_resources/2`** return shape widened —
  `{:ok, MapSet}` | `{:error, term}` | `{:unrestricted, reason}`. The bare
  `:skip` return was removed. Adapters that cannot enforce visibility at the
  statement layer return `{:unrestricted, reason}`; hosts opt in via the new
  `:allow_unrestricted_resources` config.
- **`get_table_schema/3` → `describe_table/3`**, **`resolve_table_schema/3`
  → `resolve_table_namespace/3`**. The "schema" word was used with two
  distinct meanings; the new names disambiguate.
- **`explain_plan/4` → `query_plan/4`** with return type widened to
  `{:ok, String.t() | nil} | {:error, term()}`. Non-SQL engines that don't
  expose a plan return `{:ok, nil}` without surfacing an error.
- **`transform_bound_query/4` arity → `transform_bound_query/3`** — takes
  `(state, %Statement{}, opts)`, not the old `(state, sql, params, opts)`.
- **New optional callbacks:** `needs_preflight?/2`, `validate_statement/3`,
  `parse_qualified_name/2`, `validate_identifier/3`,
  `supported_filter_operators/1`, `ai_context/1`, `prepare_for_analysis/2`.
  Each has a safe default. Adapters inherit permissive behaviour without
  needing to declare anything.
- **AI opt-in.** Adapters implement `ai_context/1` to opt into
  `Lotus.AI`. Trust model: untrusted adapters get only `:language` through
  to the prompt; free-form fields are stripped. Add the adapter to
  `:trusted_source_adapters` to allow its `syntax_notes` / `example_query` /
  `error_patterns` through.

`@deprecated` callbacks (`transform_statement/2` old shape, `transform_query/4`,
`apply_window/4`, `transform_sql/2`) were removed. No aliases.

---

## 9. `Lotus.Source` is a facade, not a behaviour

Host apps implementing `@behaviour Lotus.Source` with a custom module will
fail to compile. The callbacks that were on `Lotus.Source` moved:

- SQL-specific callbacks (quoting, placeholders, dialect-specific introspection)
  → `Lotus.Source.Adapters.Ecto.Dialect`
- Universal callbacks (execute, pipeline, lifecycle) → `Lotus.Source.Adapter`

Migration:

- For **Ecto-backed custom sources**: `use Lotus.Source.Adapters.Ecto, dialect: MyDialect`
- For **non-Ecto sources**: `@behaviour Lotus.Source.Adapter`

`Lotus.Source` itself is now a public facade with convenience functions
(`resolve!/2`, `list_sources/0`, `get_source!/1`, etc.) — still useful, just
not a behaviour anymore.

---

## 10. Visibility resolver `scope` argument

`Lotus.Visibility.Resolver` callbacks gained a second `scope` argument:

```diff
-@callback schema_rules_for(source_name :: String.t()) :: [...]
+@callback schema_rules_for(source_name :: String.t(), scope :: term()) :: [...]
-@callback table_rules_for(source_name :: String.t()) :: [...]
+@callback table_rules_for(source_name :: String.t(), scope :: term()) :: [...]
-@callback column_rules_for(source_name :: String.t()) :: [...]
+@callback column_rules_for(source_name :: String.t(), scope :: term()) :: [...]
```

Custom resolvers must accept (and ignore, if unused) the `scope` argument.
The shipped `Lotus.Visibility.Resolvers.Static` ignores scope, so static
config users are unaffected.

---

## Quick-reference upgrade checklist

Order matters — do these in sequence:

1. [ ] **Host config** — rename `:ecto_repo`, `:data_repos`, `:default_repo`.
2. [ ] **DB migration (Postgres)** — run `mix ecto.migrate` to apply the
   `data_repo` → `data_source` rename.
3. [ ] **DB migration (MySQL / SQLite)** — run the manual `ALTER TABLE`
   before deploying.
4. [ ] **Callers** — grep for `Lotus.run_sql`, `Lotus.data_repos`,
   `Lotus.get_table_schema`, `Lotus.default_data_repo`, `run_sql_with_context`
   etc. Rename per §2.
5. [ ] **Middleware** — update `:sql`/`:params` → `:statement`; `:repo`
   → `:source`; `:after_get_table_schema` → `:after_describe_table`.
6. [ ] **Telemetry handlers** — `:sql`/`:params` → `statement.text`/`statement.params`.
7. [ ] **Cache tag invalidations** — `repo:<name>` → `source:<name>`.
8. [ ] **AI callers** — `suggest_optimizations` takes `:statement`; check for
   `{:error, {:ai_feature_unsupported, _, _}}` in error paths.
9. [ ] **Custom adapters** — see §8 above and the [authoring guide](source-adapters.md).
10. [ ] **Run tests.** `mix compile --warnings-as-errors` + your suite will
    catch most mismatches (the removed names fail at compile time).

---

## Reporting upgrade issues

If something in this guide is unclear or missing, please file an issue at
[elixir-lotus/lotus](https://github.com/elixir-lotus/lotus/issues) with your
v0.x → v1.0 migration scenario.
