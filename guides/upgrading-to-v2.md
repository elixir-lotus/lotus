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

