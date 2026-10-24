defmodule Lotus.Source.Adapter.Editor do
  @moduledoc """
  Capability behaviour for the query editor and the AI layer: the editor's
  language configuration, the query language identifier, an example query
  and the context the AI pipeline prompts with.

  An adapter without it gets a plain-text editor with no completions, the
  `"sql"` language and no AI features.

  Declare it next to the core behaviour and implement every callback:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Editor

  `Lotus.Source.Adapter` dispatches to these callbacks only when the module
  declares this behaviour. Exporting them without the declaration is not
  enough.
  """

  alias Lotus.Source.Adapter

  @doc """
  Return editor configuration (keywords, types, functions) for the adapter.

  ## Shape

  Required fields:

    * `:language` — query-language identifier (e.g. `"sql:postgres"`,
      `"json:elasticsearch"`). Drives CodeMirror language selection.
    * `:keywords`, `:types` — flat lists feeding the "complete any
      keyword anywhere" fallback (used when `:context_schema` is
      absent) and the AI prompt pipeline.
    * `:functions` — `%{name, detail, args}` entries for signature help.
    * `:context_boundaries` — SQL-only; ignored for JSON DSLs.

  Optional fields:

    * `:dialect_spec` — lexical rules of the SQL dialect. Forwarded verbatim to
      CodeMirror's `SQLDialect.define()`, and read by `lexical_profile/1` so
      the server tokenizes `{{var}}` and `[[...]]` template syntax with the
      same quoting and comment rules. Only meaningful for SQL languages;
      adapters on a built-in CM6 dialect (Postgres, MySQL, SQLite, MSSQL,
      MariaSQL, Cassandra, PLSQL) can omit this and get the built-in grammar
      in the editor and the profile of their `query_language/1` on the server.
    * `:context_schema` — JSON DSL structural completion schema. Drives
      parent-aware autocomplete (e.g., Elasticsearch's `bool` →
      `must`/`should`/`filter`). Omit for SQL adapters; for JSON DSL
      adapters, omitting it degrades the editor to flat keyword
      suggestions at every key position.

  ## Examples

  Plain SQL adapter — required fields only:

      %{
        language: "sql",
        keywords: ["SELECT", "FROM", "WHERE"],
        types: ["INTEGER", "TEXT"],
        functions: [%{name: "COUNT", detail: "count(*)", args: "(*)"}],
        context_boundaries: ["SELECT", "FROM", "WHERE"]
      }

  External SQL adapter with tokenizer options:

      %{
        language: "sql:clickhouse",
        keywords: [...],
        types: [...],
        functions: [...],
        context_boundaries: [...],
        dialect_spec: %{
          identifier_quotes: "`",
          hash_comments: true,
          double_quoted_strings: false,
          case_insensitive_identifiers: true
        }
      }

  JSON DSL adapter with a structural schema:

      %{
        language: "json:elasticsearch",
        keywords: [...],
        types: [],
        functions: [],
        context_boundaries: [],
        context_schema: %{
          root: ["query", "aggs", "sort"],
          children: %{
            "query" => ["match", "term", "bool"],
            "bool" => ["must", "should", "filter"],
            "must" => :array_of_query,
            "match" => :fields
          },
          value_literals: %{"order" => ["asc", "desc"]}
        }
      }

  Size caps on `:keywords`, `:types`, `:functions`, `:context_schema.root`,
  and `:context_schema.children` are enforced at the dispatch layer —
  see `Lotus.Source.Adapter.editor_config/1` for exact limits.
  """
  @callback editor_config(state :: term()) :: %{
              required(:language) => String.t(),
              required(:keywords) => [String.t()],
              required(:types) => [String.t()],
              required(:functions) => [%{name: String.t(), detail: String.t(), args: String.t()}],
              required(:context_boundaries) => [String.t()],
              optional(:dialect_spec) => Adapter.dialect_spec(),
              optional(:context_schema) => Adapter.context_schema()
            }

  @doc """
  Return the query language identifier for this source.

  Used by the AI pipeline, editor integrations, and `:schema_hierarchy` UI
  affordances to know what kind of statement text this source accepts.
  Examples:

    * `"sql:postgres"`, `"sql:mysql"`, `"sql:sqlite"` for SQL-prepared adapters
    * `"json:elasticsearch"` for an Elasticsearch DSL adapter
    * `"json:mongo"` for a MongoDB aggregation pipeline adapter

  The part before the colon is the language family. It selects the editor
  mode and the fenced-code label the AI layer asks the model to emit, so it
  must name the syntax of the statement body (`sql`, `json`, ...), not the
  engine.
  """
  @callback query_language(state :: term()) :: String.t()

  @doc "Return an example query string for placeholder text in the query editor."
  @callback example_query(state :: term(), table :: String.t(), schema :: String.t() | nil) ::
              String.t()

  @doc """
  Return the structured context the AI pipeline uses when generating
  queries for this source.

  The returned map has fixed keys:

    * `:language` — query-language identifier (same shape as
      `query_language/1`: `"sql:postgres"`, `"json:elasticsearch"`, ...).
      Must match a constrained character set; violating identifiers are
      replaced with `"unknown"` at the dispatch layer.
    * `:example_query` — one concrete example statement showing the
      adapter's syntax idioms. Capped at 2048 bytes.
    * `:syntax_notes` — short prose covering quoting, reserved words,
      or dialect-specific pitfalls. Capped at 1024 bytes.
    * `:error_patterns` — up to 20 `%{pattern: Regex.t(), hint: binary}`
      entries. When a query fails, the first matching `:pattern` feeds
      its `:hint` back into the LLM so it can self-correct.
    * `:generation_notes` — optional prose telling the LLM how to shape a
      good query for this source. Replaces core's generic guidance rather
      than being appended to it. Capped at 1024 bytes.
    * `:read_only_notes` — optional prose naming the operations this
      source treats as writes, and therefore must never be generated.
      Replaces core's generic guidance. Capped at 1024 bytes.

  Core owns prompt *structure* — the workflow, the tool list, the
  `UNABLE_TO_GENERATE` protocol, the fence. The adapter owns prompt
  *content* about its own language. This split follows the enforcement:
  `sanitize_query/3` is already an adapter callback, so the adapter, not
  core, decides what counts as a write.

  Return `{:error, :ai_not_supported}` (or any `{:error, term}`) to opt
  the source out of AI generation entirely — `Lotus.AI.generate_query_with_context/1`
  surfaces a clean "AI not supported for source" error instead of
  hallucinating syntax the adapter can't run.

  **Security note.** Untrusted adapters can influence LLM output through
  `:syntax_notes`, `:error_patterns`, `:generation_notes` and
  `:read_only_notes`. Host apps opt adapters into the full context via
  `config :lotus, :trusted_source_adapters`. Untrusted adapters see only
  `:language` plumbed to the prompt; free-form fields are discarded, and
  core falls back to its own guidance rather than to an empty string.

  Without this capability: `{:error, :ai_not_supported}` — the
  adapter is opted out of AI.
  """
  @callback ai_context(state :: term()) :: {:ok, Adapter.ai_context_map()} | {:error, term()}
end
