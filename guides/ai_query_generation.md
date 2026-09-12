# AI Query Generation

> ⚠️ **Experimental Feature**: This feature is experimental and disabled by default. The API may change in future versions.

Lotus includes experimental support for generating queries from natural language descriptions using Large Language Models (LLMs). The pipeline is adapter-driven: it generates whatever query language the resolved source speaks, not SQL only. This guide covers setup, usage, and best practices.

## Overview

The AI query generation feature:

- **Disabled by default** - Requires explicit configuration
- **BYOK (Bring Your Own Key)** - You provide API keys and pay for usage directly
- **Adapter-driven** - The source adapter supplies the query language, an example query, and its own syntax notes through `ai_context/1`
- **Schema-aware** - Introspects your data source structure automatically
- **Respects visibility** - Only sees tables/columns allowed by your Lotus visibility rules
- **Read-only by default** - Pass `read_only: false` to let the AI generate write queries
- **Multi-provider** - Works with any provider supported by [ReqLLM](https://github.com/agentjido/req_llm) (OpenAI, Anthropic, Google, Groq, Mistral, and more)
- **Conversational** - Multi-turn conversations for iterative query refinement and error fixing
- **Variable-aware** - Generates query variable configurations with UI metadata (widget types, labels, dropdown options)
- **Query explanation** - Get plain-language explanations of full queries or selected fragments
- **Query optimization** - Analyzes execution plans and suggests indexes, rewrites, and structural changes
- **Per-source capability gates** - Each adapter declares which of the three AI features it supports, so a UI can disable a button per source

> **Web-first design:** The AI module is designed to work hand-in-hand with the [Lotus Web](https://github.com/elixir-lotus/lotus_web) interface. Generated variable configurations — widget types, labels, static options, and options queries — map directly to the web editor's `WidgetComponent`, which renders them as text inputs, dropdowns, multi-selects, date pickers, and tag inputs. While the API is usable standalone, the variable metadata is most valuable when paired with the web UI.

## Who Writes the Prompt

Lotus core owns prompt **structure**; the source adapter owns prompt
**content** about its own query language.

| Core writes it | The adapter writes it |
|---|---|
| The workflow and the tool list | `:language` |
| `{{var}}` / `[[optional]]` template rules | `:example_query` |
| The `UNABLE_TO_GENERATE` protocol | `:syntax_notes` |
| The fence protocol | `:generation_notes` |
| A generic default for each notes field | `:read_only_notes` |

This follows the enforcement: `sanitize_query/3` is already an adapter
callback, so the adapter decides what counts as a write. Before v1.0, core
sent SQL-specific guidance ("use JOINs", "add LIMIT", "never generate
INSERT / UPDATE / DELETE") to every source, including non-SQL ones where
those operations do not exist.

Adapter notes render **in place of** core's defaults, never appended after
them, so an adapter speaks for its own language instead of arguing with
core's. An adapter that omits a field gets core's generic text. An adapter
that is not in `:trusted_source_adapters` has its notes dropped and also
gets core's text — never an empty string, which would leave the prompt with
no read-only instruction at all.

Core asks for the generated statement inside a fence labelled with the
adapter's language **family** — `sql` for `sql:postgres`, `json` for
`json:elasticsearch`. See the [source adapters
guide](source-adapters.md#ai-adapter-support) for how to supply these.

### The Trust Boundary

An adapter's free-form `ai_context/1` text goes into an LLM prompt, so it is
a prompt-injection surface. `:trusted_source_adapters` is the allowlist:

```elixir
config :lotus,
  trusted_source_adapters: [MyApp.ClickHouseAdapter]
```

The built-in `Lotus.Source.Adapters.Ecto` and its per-dialect wrappers
(`Postgres`, `MySQL`, `SQLite3`) are always trusted; you do not list them.

For an adapter that is **not** on the list, Lotus keeps only `:language`
and strips `:example_query`, `:syntax_notes`, `:error_patterns`,
`:generation_notes` and `:read_only_notes`. The two notes keys are
*dropped*, not blanked, so the prompt layer falls back to core's own text.
That distinction matters: a blank `:read_only_notes` would leave the prompt
with no read-only instruction at all, which is exactly how an untrusted
adapter would weaken the guard. Capability `{false, reason}` strings from an
untrusted adapter are likewise replaced with a generic fallback sentence.

Lotus logs the strip once per adapter, at `:info`, and only when the adapter
actually supplied something to strip.

## Per-Source Capability Gates

An adapter's `ai_context/1` may declare `:capabilities` — one entry per AI
feature, each either `true` or `{false, reason}`:

```elixir
%{generation: true, optimization: {false, "This engine exposes no query plan."}, explanation: true}
```

An adapter that omits `:capabilities` gets all three as `true`. An adapter
that returns `{:error, _}` from `ai_context/1` is out of AI entirely.

Query the gates before you render a button:

```elixir
Lotus.AI.supports?("warehouse", :optimization)
#=> false

Lotus.AI.unsupported_reason("warehouse", :optimization)
#=> "This engine exposes no query plan."

Lotus.AI.unsupported_reason("warehouse", :generation)
#=> nil
```

The features are `:generation`, `:optimization` and `:explanation`. The
reason string is safe to show verbatim — untrusted adapters never reach a
user with their own wording.

Every public AI function also enforces the gate itself, so a caller that
skips the check gets a structured error rather than a hallucinated query:

```elixir
{:error, {:ai_feature_unsupported, :optimization, "This engine exposes no query plan."}} =
  Lotus.AI.suggest_optimizations(statement: statement, data_source: "warehouse")
```

## Saved Queries Record Their Language

A query saved through `Lotus.Storage` records the `query_language` of the
source it was written for. At execution, Lotus refuses to run it against a
source that speaks a different language, rather than passing, say, Postgres
SQL to ClickHouse and surfacing a confusing syntax error:

```
Query was written for "sql:postgres" but data source "warehouse" speaks "sql:clickhouse"
```

Queries saved without a language run anywhere, which is how every query
predating the column behaves.

## Supported Providers

Any provider supported by ReqLLM can be used. Common examples:

| Provider | Example Model String | Notes |
|----------|---------------------|-------|
| OpenAI | `"openai:gpt-4o"` | Default if no model configured |
| Anthropic | `"anthropic:claude-opus-4"` | |
| Google | `"google:gemini-2.0-flash"` | |
| Groq | `"groq:llama-3.3-70b-versatile"` | |
| Mistral | `"mistral:mistral-large-latest"` | |

See the [ReqLLM documentation](https://hexdocs.pm/req_llm) for the full list of supported providers.

## Installation

Lotus includes the `req_llm` dependency automatically. No additional packages needed.

## Configuration

### Basic Setup

Configure in your `config/config.exs` or `config/runtime.exs`:

```elixir
config :lotus, :ai,
  enabled: true,
  model: "openai:gpt-4o",
  api_key: {:system, "OPENAI_API_KEY"}
```

The `model` key accepts any ReqLLM model string in `"provider:model"` format.

### Using Environment Variables (Recommended)

```elixir
# config/runtime.exs
config :lotus, :ai,
  enabled: true,
  model: System.get_env("AI_MODEL", "openai:gpt-4o"),
  api_key: System.get_env("AI_API_KEY")
```

Then set environment variables:

```bash
export AI_MODEL=openai:gpt-4o
export AI_API_KEY=sk-proj-...
```

## Usage

### Basic Query Generation (Single-Turn)

For simple, one-off queries without conversation context:

```elixir
{:ok, result} = Lotus.AI.generate_query(
  prompt: "Show all users who signed up in the last 7 days",
  data_source: "my_repo"
)

result.statement
#=> "SELECT * FROM users WHERE created_at > NOW() - INTERVAL '7 days'"

result.variables
#=> []

result.model
#=> "openai:gpt-4o"

result.usage
#=> %{prompt_tokens: 245, completion_tokens: 28, total_tokens: 273}
```

When the user asks for parameterized queries, the AI also returns variable configurations:

```elixir
{:ok, result} = Lotus.AI.generate_query(
  prompt: "Show orders filtered by a status dropdown",
  data_source: "my_repo"
)

result.statement
#=> "SELECT * FROM orders WHERE status = {{status}}"

result.variables
#=> [%{"name" => "status", "type" => "text", "widget" => "select",
#=>    "label" => "Order Status",
#=>    "static_options" => [%{"value" => "pending", "label" => "Pending"}, ...]}]
```

For iterative refinement and error fixing, see [Conversational Query Refinement](#conversational-query-refinement) below.

### Error Handling

```elixir
case Lotus.AI.generate_query(prompt: prompt, data_source: repo) do
  {:ok, result} ->
    # Success - use result.statement

  {:error, :not_configured} ->
    # AI features not enabled in config

  {:error, :api_key_not_configured} ->
    # API key missing or invalid

  {:error, {:unable_to_generate, reason}} ->
    # LLM couldn't generate query (e.g., "This is a weather question")

  {:error, {:ai_feature_unsupported, feature, reason}} ->
    # The adapter declared this feature unsupported for this source

  {:error, :ai_not_supported_for_source} ->
    # The adapter returned {:error, _} from ai_context/1 — no AI at all

  {:error, :missing_data_source} ->
    # :data_source was not passed

  {:error, reason} ->
    # Other error (network, timeout, etc.)
end
```

### Allowing Write Queries

Generation is read-only by default. Pass `read_only: false` to lift the
restriction — the prompt then carries core's write-permitted text instead of
the adapter's read-only notes:

```elixir
{:ok, result} = Lotus.AI.generate_query(
  prompt: "Mark order 42 as shipped",
  data_source: "my_repo",
  read_only: false
)
```

This only changes what the LLM is *asked* to produce. Execution is gated
separately: `Lotus.run_statement/3` and `Lotus.run_query/2` still refuse
writes unless you also pass `read_only: false` there.

### Complex Queries

The AI uses multiple tools to understand your schema:

```elixir
# Complex query with joins across schemas
Lotus.AI.generate_query(
  prompt: "Which customers have outstanding invoices with their total amount owed",
  data_source: "analytics_db"
)

# Behind the scenes, the AI will:
# 1. Call list_schemas() to find "reporting" schema
# 2. Call list_tables() to find "customers" and "invoices" tables
# 3. Call describe_table() for both tables
# 4. Call get_column_values("invoices", "status") to check valid statuses
# 5. Generate: SELECT c.name, SUM(i.amount) FROM reporting.customers c ...
```

## How It Works

### Schema Introspection Tools

During generation the AI has access to these tools:

1. **`list_schemas()`** - Get all schemas (namespaces) in the source
2. **`list_tables()`** - Get tables with schema-qualified names
3. **`describe_table(table_name)`** - Get columns, types, constraints
4. **`get_column_values(table_name, column_name)`** - Get distinct values (enums, statuses)
5. **`validate_statement(statement)`** - Check syntax against the source without executing

Explanation and optimization are given only `describe_table`, since they
already have the statement in hand.

Two further actions ship but are not wired into any built-in flow — they
are building blocks for host-written agents, reachable through
`Lotus.AI.Actions.investigation_actions/0`:

- **`list_data_sources()`** - List the configured data sources
- **`execute_statement(statement)`** - Run a read-only statement and return a row preview

All tools respect your Lotus visibility rules - the AI sees exactly what your users see.

Tool names are part of the adapter-facing contract: adapters refer to them
in their own `error_patterns` hints. `validate_statement` and
`execute_statement` were named `validate_sql` and `execute_sql` before v1.0.

### Query Generation Process

1. **Parse prompt** - LLM analyzes the natural language request
2. **Discover schema** - Calls tools to find relevant tables
3. **Introspect tables** - Gets column details for identified tables
4. **Check enum values** - For status/type columns, gets actual values
5. **Generate the statement** - Produces a schema-qualified, type-safe statement
6. **Validate** - Calls `validate_statement()` and fixes any error before returning

### Example: Status Value Discovery

Instead of guessing:

```sql
-- ❌ AI assumes status value
WHERE status = 'outstanding'  -- might not exist!
```

The AI checks first:

```elixir
# AI calls: get_column_values("invoices", "status")
# Returns: ["open", "paid", "overdue"]

# Then generates:
WHERE status IN ('open', 'overdue')  -- ✅ uses actual values
```

## Acting on Behalf of a User

Every AI action — listing tables, describing a table, sampling column values,
running a generated query — goes through the same `Lotus` functions a direct
call would. Pass `:context` and `:scope` so those calls carry the actor:

```elixir
Lotus.AI.generate_query(
  prompt: "Show orders from this month",
  data_source: "my_repo",
  context: %{user_id: current_user.id},
  scope: %{tenant_id: current_user.tenant_id}
)
```

`:context` reaches your middleware; `:scope` reaches your visibility
resolver. Without them the AI runs unscoped, which means it can see tables
your user cannot — and any access-control plug you wrote sees `nil` for
every AI-initiated action.

Custom actions receive the same map as the second argument to `run/2`, and
should pass it on:

```elixir
def run(params, context) do
  Lotus.Schema.list_tables(params.data_source, Lotus.AI.Action.actor_opts(context))
end
```

## Best Practices

### 1. Use Descriptive Prompts

**Good:**
- "Show customers with unpaid invoices sorted by amount owed"
- "Find users who haven't logged in during the last 30 days"
- "Calculate monthly revenue from the orders table"

**Too Vague:**
- "Show me some data" ❌
- "Users" ❌

### 2. Mention Specific Tables

Help the AI by referencing table names:

```elixir
"Show sales from the orders table grouped by month"
```

### 3. Specify Time Ranges

Be clear about dates:

```elixir
"Users created in the last 7 days"  # ✅
"Recent users"  # ❌ ambiguous
```

### 4. Review Generated Queries

Always review the generated statement before using it in production:

```elixir
{:ok, result} = Lotus.AI.generate_query(prompt: prompt, data_source: repo)

IO.puts("Generated statement:")
IO.puts(result.statement)

# Review before executing:
Lotus.run_statement(result.statement, [], repo: repo)
```

## Visibility and Security

### AI Respects Visibility Rules

The AI assistant only sees what your Lotus visibility configuration allows:

```elixir
# config/config.exs
config :lotus,
  table_visibility: %{
    default: [
      deny: [
        {"public", "api_keys"},      # ✅ Hidden from AI
        {"public", "user_sessions"}   # ✅ Hidden from AI
      ]
    ]
  }
```

If a user asks "Show me all API keys", the AI will respond:

```
UNABLE_TO_GENERATE: api_keys table not available
```

### Read-Only Execution

AI-generated queries are executed through the same pipeline as any other
query, so they inherit Lotus's read-only guarantees:

- Queries run read-only unless the caller passes `read_only: false`
- What counts as a write is the adapter's call — `sanitize_query/3` is an
  adapter callback, so an SQL adapter blocks `INSERT` / `UPDATE` / `DELETE`
  and DDL, while a non-SQL adapter blocks whatever its own engine's write
  operations are
- The prompt tells the LLM the same thing, in the adapter's own words, via
  `ai_context.read_only_notes`

## Cost Management

### Token Usage

Each query generation consumes tokens from your API provider. Check your usage:

```elixir
{:ok, result} = Lotus.AI.generate_query(...)

result.usage
#=> %{
#=>   prompt_tokens: 450,      # Input (schema info + prompt)
#=>   completion_tokens: 42,   # Output (generated statement)
#=>   total_tokens: 492
#=> }
```

Refer to your provider's pricing page for current rates.

### Reducing Token Usage

1. **Use cheaper models** for simple queries
2. **Be specific in prompts** to minimize tool calls

## Troubleshooting

### "AI features are not configured"

Enable AI in your config:

```elixir
config :lotus, :ai,
  enabled: true,
  model: "openai:gpt-4o",
  api_key: "sk-..."
```

### "API key is missing or invalid"

Check your API key:

```elixir
# Verify environment variable is set
System.get_env("OPENAI_API_KEY")

# Or check config
Application.get_env(:lotus, :ai)
```

### "Unable to generate query: ..."

The LLM refused to generate a statement. Common reasons:

- Question not related to database ("What's the weather?")
- Required tables not visible
- Ambiguous or incomplete prompt

### Queries are slow

AI query generation typically takes 2-10 seconds depending on:

- Database complexity (more tables = more tool calls)
- LLM provider and model
- Network latency

## Conversational Query Refinement

The AI supports multi-turn conversations, allowing you to iteratively refine queries, fix errors, and have back-and-forth dialogue.

### Basic Conversation Flow

```elixir
alias Lotus.AI.Conversation

# Start a new conversation
conversation = Conversation.new()

# First query attempt
conversation = Conversation.add_user_message(conversation, "Show active users")

{:ok, result} = Lotus.AI.generate_query_with_context(
  prompt: "Show active users",
  data_source: "postgres",
  conversation: conversation
)

# Add the AI response to conversation
conversation = Conversation.add_assistant_response(
  conversation,
  "Here's your query:",
  result.statement,
  result.variables
)

# If the query fails, add the error
case Lotus.run_statement(result.statement, [], repo: "postgres") do
  {:ok, _} ->
    :success
  {:error, error} ->
    conversation = Conversation.add_query_result(conversation, {:error, error})
end

# Ask the AI to fix the error - it has full context
{:ok, fixed_result} = Lotus.AI.generate_query_with_context(
  prompt: "Fix the error",
  data_source: "postgres",
  conversation: conversation
)
```

### Iterative Refinement

Users can refine queries conversationally:

```elixir
conversation = Conversation.new()

# Initial request
{:ok, result1} = Lotus.AI.generate_query_with_context(
  prompt: "Show user signups by month",
  data_source: "postgres",
  conversation: conversation
)

conversation = Conversation.add_assistant_response(conversation, "Generated query", result1.statement, result1.variables)

# Refine the query
conversation = Conversation.add_user_message(conversation, "Only show the last 6 months")

{:ok, result2} = Lotus.AI.generate_query_with_context(
  prompt: "Only show the last 6 months",
  data_source: "postgres",
  conversation: conversation
)
# The AI remembers the previous query and modifies it accordingly
```

### Automatic Error Recovery

Conversations enable automatic error detection and fixing:

```elixir
# Check if the last message was an error
if Conversation.should_auto_retry?(conversation) do
  # Automatically retry with full error context
  Lotus.AI.generate_query_with_context(
    prompt: "Fix the error",
    data_source: "postgres",
    conversation: conversation
  )
end
```

### Managing Long Conversations

Prevent token overflow by pruning old messages:

```elixir
# Keep only the last 10 messages
conversation = Conversation.prune_messages(conversation, 10)
```

## Query Explanation

Lotus can explain what a query does in plain language, powered by AI. This helps users understand complex queries written by others (or generated by AI) without mentally parsing them. The examples below are SQL because the source is Postgres; the explainer works for whatever language the source adapter declares.

### Explaining a Full Query

```elixir
{:ok, result} = Lotus.AI.explain_query(
  statement: """
  SELECT d.name, COUNT(o.id), SUM(o.total)
  FROM departments d
  LEFT JOIN employees e ON e.department_id = d.id
  LEFT JOIN orders o ON o.employee_id = e.id
  WHERE o.created_at >= NOW() - INTERVAL '30 days'
  GROUP BY d.name
  HAVING SUM(o.total) > 10000
  ORDER BY SUM(o.total) DESC
  """,
  data_source: "my_repo"
)

result.explanation
#=> "This query shows departments ranked by total order revenue in the last
#=>  30 days. It joins departments to employees to orders, groups by department
#=>  name, and only includes departments with more than $10,000 in total orders.
#=>  Results are sorted from highest to lowest revenue."
```

### Explaining a Selected Fragment

Users can highlight a portion of the query to explain just that part. The full query is sent as context so the AI can accurately explain even isolated terms like a single JOIN, a HAVING clause, or a function call.

```elixir
{:ok, result} = Lotus.AI.explain_query(
  statement: "SELECT d.name FROM departments d LEFT JOIN employees e ON e.department_id = d.id",
  fragment: "LEFT JOIN employees e ON e.department_id = d.id",
  data_source: "my_repo"
)

result.explanation
#=> "This LEFT JOIN connects the departments table to the employees table by
#=>  matching each department's id with the employee's department_id. It keeps
#=>  all departments in the result even if they have no employees."
```

### Lotus Variable Syntax

The explainer understands Lotus-specific `{{variable}}` placeholders and `[[optional clause]]` brackets and explains their runtime behavior:

```elixir
{:ok, result} = Lotus.AI.explain_query(
  statement: """
  SELECT id, name, status FROM users
  WHERE 1=1
  [[AND status = {{status}}]]
  [[AND created_at > {{start_date}}]]
  ORDER BY id
  """,
  data_source: "my_repo"
)

#=> "This query retrieves users filtered by optional conditions. The status
#=>  filter only applies when the user provides a status value at runtime;
#=>  otherwise it is skipped. Similarly, the created_at filter is optional
#=>  and only included when a start_date is supplied."
```

### Error Handling

```elixir
case Lotus.AI.explain_query(statement: statement, data_source: repo) do
  {:ok, %{explanation: explanation}} ->
    # Display explanation to user

  {:error, :not_configured} ->
    # AI features not enabled

  {:error, reason} ->
    # Other error
end
```

## Query Optimization

Lotus can analyze a query and suggest performance improvements, using the
engine's own execution plan where one is available.

`:statement` here is a `%Lotus.Query.Statement{}`, not a string — the
optimizer hands it to the adapter, which owns the body's shape. Build one
with `Lotus.Query.Statement.new/2`, or take the one
`Lotus.Storage.Query.compile/2` returns for a stored query.

### Basic Usage

```elixir
statement = Lotus.Query.Statement.new("SELECT * FROM orders WHERE created_at > '2024-01-01'")

{:ok, result} = Lotus.AI.suggest_optimizations(
  statement: statement,
  data_source: "my_repo"
)

result.suggestions
#=> [
#=>   %{
#=>     "type" => "index",
#=>     "impact" => "high",
#=>     "title" => "Add index on orders.created_at",
#=>     "suggestion" => "CREATE INDEX idx_orders_created_at ON orders (created_at);\n\nThe query filters on created_at but no index exists..."
#=>   },
#=>   %{
#=>     "type" => "rewrite",
#=>     "impact" => "medium",
#=>     "title" => "Select only needed columns",
#=>     "suggestion" => "Replace SELECT * with specific columns..."
#=>   }
#=> ]

result.model
#=> "openai:gpt-4o"
```

### Suggestion Types

Each suggestion includes a `type` and `impact` level:

| Type | Description |
|------|-------------|
| `index` | Missing or suboptimal indexes |
| `rewrite` | Query structure improvements |
| `structure` | Table, collection, or mapping design changes |
| `configuration` | Engine configuration tuning |

A suggestion whose `type` is not one of these four is normalized to
`rewrite` rather than discarded.

| Impact | Description |
|--------|-------------|
| `high` | Significant performance improvement expected |
| `medium` | Moderate improvement |
| `low` | Minor improvement |

### How It Works

1. Calls the adapter's `prepare_for_analysis/2` to make the statement
   parseable by the engine's diagnostic endpoint
2. Calls the adapter's `query_plan/3` for an execution plan — `EXPLAIN`
   output for SQL dialects, a native profile response elsewhere
3. Sends the statement and the plan to the AI for analysis
4. The AI can call `describe_table()` for deeper analysis
5. Returns structured suggestions with actionable recommendations

An adapter that cannot produce a plan is not an error. `query_plan/3` may
return `{:ok, nil}`, and `prepare_for_analysis/2` may return
`{:error, :unsupported}`; in either case the optimizer sends the statement
with no plan and the AI reviews it structurally.

### Lotus Variable Syntax

Statements using Lotus-specific syntax (`{{variables}}` and `[[optional
clauses]]`) are handled by `prepare_for_analysis/2`. For the built-in Ecto
adapter that means:

- `[[...]]` brackets are removed (content kept) so `EXPLAIN` sees all clauses
- `{{variable}}` placeholders are replaced with `NULL`

Other adapters substitute whatever null-ish literal their language wants.
The statement sent to the AI is the original one, Lotus syntax intact.

```elixir
statement =
  Lotus.Query.Statement.new("""
  SELECT id, name FROM users
  WHERE 1=1
  [[AND status = {{status}}]]
  [[AND created_at > {{start_date}}]]
  ORDER BY id
  """)

{:ok, result} = Lotus.AI.suggest_optimizations(
  statement: statement,
  data_source: "my_repo"
)
```

### Options

- `:statement` (required) - A `%Lotus.Query.Statement{}` to review
- `:data_source` (required) - Name of the data source
- `:search_path` (optional) - PostgreSQL search path
- `:context` / `:scope` (optional) - See [Acting on Behalf of a User](#acting-on-behalf-of-a-user)

### Error Handling

```elixir
case Lotus.AI.suggest_optimizations(statement: statement, data_source: repo) do
  {:ok, %{suggestions: []}} ->
    # Query is already well-optimized

  {:ok, %{suggestions: suggestions}} ->
    # Process suggestions

  {:error, :not_configured} ->
    # AI features not enabled

  {:error, reason} ->
    # Other error
end
```

## Limitations

- **English prompts recommended** - Other languages may work but aren't tested
- **Token limits** - Very long conversations may need pruning to stay within model limits

## API Reference

Every AI entry point returns the shared error tuples
`{:error, :not_configured}`, `{:error, :api_key_not_configured}`,
`{:error, :missing_data_source}`,
`{:error, {:ai_feature_unsupported, feature, reason}}`,
`{:error, :ai_not_supported_for_source}` and `{:error, term()}`. Only the
extra ones are listed below.

### `Lotus.AI.generate_query/1`

Generates a statement from natural language (single-turn).

**Options:**

- `:prompt` (required) - Natural language description
- `:data_source` (required) - Data source name
- `:read_only` (optional) - Restrict generation to read-only queries (default: `true`)
- `:context` / `:scope` (optional) - Actor threaded into every query and discovery call

**Returns:**

- `{:ok, %{statement: String.t(), variables: [map()], model: String.t(), usage: map()}}` - Success
- `{:error, {:unable_to_generate, reason}}` - LLM refused

### `Lotus.AI.generate_query_with_context/1`

Generates a statement with conversation context for multi-turn refinement.

**Options:**

- `:prompt` (required) - Natural language description
- `:data_source` (required) - Data source name
- `:conversation` (optional) - Conversation state with message history
- `:query_context` (optional) - `%{statement: ..., variables: [...]}` describing the query already in the user's editor
- `:read_only` (optional) - Restrict generation to read-only queries (default: `true`)
- `:context` / `:scope` (optional) - Actor threaded into every query and discovery call

**Returns:**

Same as `generate_query/1`.

### `Lotus.AI.Conversation`

Manages conversational state for multi-turn interactions. The state is a
plain map, not a struct, and every message carries `:statement` — never
`:sql`.

**Key Functions:**

- `Conversation.new()` - Initialize a new conversation
- `Conversation.add_user_message(conversation, content)` - Add user message
- `Conversation.add_assistant_response(conversation, content, statement, variables \\ [])` - Add AI response
- `Conversation.add_query_result(conversation, result)` - Add query execution result (success or error)
- `Conversation.should_auto_retry?(conversation)` - Check if last message was an error
- `Conversation.prune_messages(conversation, keep_last \\ 10)` - Remove old messages to manage token usage
- `Conversation.update_source_context(conversation, tables)` - Track analyzed tables under `:source_context`

### `Lotus.AI.explain_query/1`

Explains a query (or a selected fragment) in plain language.

**Options:**

- `:statement` (required) - The full statement to explain, as text
- `:fragment` (optional) - A selected portion of the query to explain
- `:data_source` (required) - Data source name
- `:context` / `:scope` (optional) - Actor threaded into the `describe_table` tool

**Returns:**

- `{:ok, %{explanation: String.t(), model: String.t(), usage: map()}}` - Success

### `Lotus.AI.suggest_optimizations/1`

Analyzes a statement and returns optimization suggestions.

**Options:**

- `:statement` (required) - A `%Lotus.Query.Statement{}` to review
- `:data_source` (required) - Data source name
- `:search_path` (optional) - PostgreSQL search path
- `:context` / `:scope` (optional) - Actor threaded into the `describe_table` tool

**Returns:**

- `{:ok, %{suggestions: [map()], model: String.t(), usage: map()}}` - Success

### `Lotus.AI.enabled?/0`

Checks if AI features are enabled.

```elixir
if Lotus.AI.enabled?() do
  # Show AI button in UI
end
```

### `Lotus.AI.supports?/2` and `Lotus.AI.unsupported_reason/2`

Per-source, per-feature gates. `feature` is `:generation`,
`:optimization` or `:explanation`.

```elixir
Lotus.AI.supports?("my_repo", :explanation)
#=> true

Lotus.AI.unsupported_reason("my_repo", :explanation)
#=> nil
```

`unsupported_reason/2` returns `nil` when the feature is supported, and a
displayable string otherwise. Both raise if the source name does not
resolve.

### `Lotus.AI.model/0`

Returns the configured model string.

```elixir
Lotus.AI.model()
#=> {:ok, "openai:gpt-4o"}
```

Returns `{:error, :not_configured}` or `{:error, :api_key_not_configured}`
when AI is not usable.

### `Lotus.AI.ErrorDetector`

Classifies a failed query's error message and suggests fixes, for feeding
back into a conversation.

```elixir
Lotus.AI.ErrorDetector.analyze_error(
  "column \"status\" does not exist",
  "SELECT status FROM users",
  %{tables_analyzed: ["users"]}
)
#=> %{
#=>   error_type: :column_not_found,
#=>   error_message: "column \"status\" does not exist",
#=>   failed_statement: "SELECT status FROM users",
#=>   suggestions: ["Use describe_table('users') to see the actual column names ...", ...]
#=> }
```

The key is `:failed_statement` (it was `:failed_sql` before v1.0). An
optional fourth argument takes the sanitized `ai_context` map; its
`:error_patterns` are matched against the message and the matching hints
are prepended to `:suggestions`. Untrusted adapters have that list stripped
to `[]` upstream, so only the generic suggestions remain.
