# Upgrading to Lotus v2.0

Lotus v2.0 is not released yet. This guide grows while the 1.x line is
current: each time a 1.x release deprecates something, the item is added
here with the replacement. Every item compiles with a warning on 1.x and is
removed in v2.0, so a host app or adapter can migrate one item at a time and
reach v2.0 with nothing left to change.

The full list lives in the `Deprecated` sections of the
[CHANGELOG](../CHANGELOG.md).

---

## 1. `Lotus.Source.Adapters.Ecto.SQL.*` moved to `Lotus.SQL.*`

The SQL helpers that any SQL engine needs sat under the Ecto adapter's
namespace, although none of them depends on Ecto. They now live in the
neutral `Lotus.SQL` namespace, next to `Lotus.Query.Tokenizer`, with the same
functions:

| Deprecated | Replacement |
|---|---|
| `Lotus.Source.Adapters.Ecto.SQL.FilterInjector` | `Lotus.SQL.FilterInjector` |
| `Lotus.Source.Adapters.Ecto.SQL.SortInjector` | `Lotus.SQL.SortInjector` |
| `Lotus.Source.Adapters.Ecto.SQL.Transformer` | `Lotus.SQL.Transformer` |
| `Lotus.Source.Adapters.Ecto.SQL.Identifier` | `Lotus.SQL.Identifier` |
| `Lotus.Source.Adapters.Ecto.SQL.Sanitizer` | `Lotus.SQL.Sanitizer` |
| `Lotus.Source.Adapters.Ecto.SQL.Validator` | `Lotus.SQL.Validator` |

The old modules delegate to the new ones and every function is marked
`@deprecated`, so the compiler names the replacement at each call site.

Who is affected: a custom `Lotus.Source.Adapters.Ecto.Dialect` such as
`lotus_clickhouse`, and any adapter that reuses the helpers directly. Host
apps that go through `Lotus.Source.Adapter` callbacks (`apply_filters/3`,
`apply_sorts/3`, `validate_statement/3`, `validate_identifier/3`,
`parse_qualified_name/2`) are not affected.

```diff
-  alias Lotus.Source.Adapters.Ecto.SQL.FilterInjector
-  alias Lotus.Source.Adapters.Ecto.SQL.SortInjector
-  alias Lotus.Source.Adapters.Ecto.SQL.Transformer
+  alias Lotus.SQL.FilterInjector
+  alias Lotus.SQL.SortInjector
+  alias Lotus.SQL.Transformer
```

The delegates are removed in v2.0.

---

## 2. `Lotus.Preflight.Relations` no longer stores state in the process dictionary

`Lotus.Preflight.Relations.put/1`, `get/0`, `take/0` and `clear/0` are
deprecated and removed in v2.0. They kept a preflight outcome in the process
dictionary, which is invisible to supervision, leaks across queries in a
reused process and cannot cross a `Task` boundary. `Lotus.Runner` carries
the outcome as a value and has not touched the process dictionary since the
outcome started travelling through the pipeline.

Who is affected: a host or middleware that stored an outcome itself and read
it back later. Nothing in `lotus_web` does.

Where to get the outcome instead:

- **In middleware**, read the `:relations` key of the `:before_execute` or
  `:after_query` payload. Both carry the same value: a `{schema, table}`
  list, `{:unrestricted, reason}` or `{:skipped, reason}`.
- **Anywhere else**, call `Lotus.Preflight.analyze/4` with the adapter and
  the statement and keep the result in your own state.

```diff
   def call(:before_execute, payload, _opts) do
-    relations = Lotus.Preflight.Relations.get()
+    relations = payload.relations
     gate(relations, payload)
   end
```

`Lotus.Preflight.Relations.to_list/1` and the `relation/0` and `outcome/0`
types stay.


---

## 3. Adapter capabilities are declared, not detected

`Lotus.Source.Adapter` was one behaviour with 41 callbacks, 32 of them
optional, and Lotus checked `function_exported?/3` on every call to decide
what an adapter could do. In v2.0 it is the core behaviour with the nine
required callbacks, and the rest live in five capability behaviours:

| Behaviour | Callbacks |
|---|---|
| `Lotus.Source.Adapter.Introspection` | `list_schemas/1`, `resolve_table_namespace/3`, `default_schemas/1`, `builtin_schema_denies/1`, `hierarchy_label/1`, `parse_qualified_name/2`, `validate_identifier/3`; optionally `table_stats/3`, `table_row_estimates/2` |
| `Lotus.Source.Adapter.Preflight` | `extract_accessed_resources/2`, `needs_preflight?/2`, `sanitize_query/3`, `query_plan/3`, `validate_statement/3`, `prepare_for_analysis/2` |
| `Lotus.Source.Adapter.Binding` | `transform_statement/2`, `substitute_variable/5`, `substitute_list_variable/5`, `transform_bound_query/3`, `db_type_to_lotus_type/2` |
| `Lotus.Source.Adapter.Shaping` | `apply_filters/3`, `apply_sorts/3`, `apply_pagination/3`, `limit_query/3`, `supported_filter_operators/1`, `quote_identifier/2` |
| `Lotus.Source.Adapter.Editor` | `editor_config/1`, `query_language/1`, `example_query/3`, `ai_context/1` |

`supports_feature?/2`, `can_handle?/1`, `wrap/2` and the process callbacks
(`shared_children/0`, `source_children/2`, `source_started/2`,
`source_stopped/2`) stay optional callbacks of the core behaviour.

Lotus now calls a capability's callbacks only when the adapter declares its
behaviour. An adapter written against the flat behaviour still compiles, but
the callbacks it exports without the declaration are ignored: an adapter
that implements `apply_filters/3` without
`@behaviour Lotus.Source.Adapter.Shaping` silently loses filtering. Lotus
logs a warning the first time it sees such a module.

There is no 1.x deprecation for this change; it lands in v2.0 only.

Who is affected: an adapter that implements `Lotus.Source.Adapter` directly,
such as `lotus_elasticsearch`. Adapters built with
`use Lotus.Source.Adapters.Ecto, dialect: ...` (such as `lotus_clickhouse`)
declare every capability through the macro and need no change. Host apps
that call `Lotus.Source.Adapter` dispatch functions are not affected.

What to do:

1. Declare the capability behaviours whose callbacks your adapter
   implements:

   ```diff
    defmodule MyApp.Adapters.Search do
      @behaviour Lotus.Source.Adapter
   +  @behaviour Lotus.Source.Adapter.Introspection
   +  @behaviour Lotus.Source.Adapter.Preflight
   +  @behaviour Lotus.Source.Adapter.Shaping
   +  @behaviour Lotus.Source.Adapter.Editor
   ```

2. Fix the compiler warnings for callbacks a declared capability is missing.
   Return the default from the
   [source adapters guide](source-adapters.md#core-and-capability-behaviours)
   when your source has nothing better.

3. Run `mix lotus.adapter.check MyApp.Adapters.Search`. It lists each
   capability as declared or not, and fails when the module exports
   callbacks of a capability it does not declare.

`%Lotus.Source.Adapter{}` has a new `:capabilities` field, filled by
`Lotus.Source.Adapter.with_capabilities/1`. `Lotus.Source.Resolvers.Static`
and the built-in Ecto adapters fill it, so dispatch reads the struct instead
of the module. A custom `wrap/2` or resolver may call it; a struct without it
still works.
