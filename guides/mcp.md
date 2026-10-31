# MCP Server

Lotus ships an [MCP](https://modelcontextprotocol.io) server, `Lotus.MCP`,
built on [Sake](https://hexdocs.pm/sake). Connect Claude Code (or Claude
Desktop, or any MCP client) to your app and ask it about your data without
opening the admin panel: it reads the saved queries and dashboards you
already have, runs its own read-only queries, and saves new queries,
charts and dashboards that then show up in Lotus Web.

Lotus Web isn't required: this guide sets up `Lotus.MCP` with Lotus
alone, and an agent gets every tool. With Lotus Web, serve its
`Lotus.Web.MCP` instead, which adds charts in the conversation and lets
your dashboard resolver decide who may do what (see Lotus Web's MCP
guide).

No LLM API key is involved: the MCP client is the model, and Lotus only
supplies tools. The [AI query generation](ai_query_generation.md) feature
is separate and stays optional.

## What the client can do

| Tool | Scope | What it does |
|---|---|---|
| `list_data_sources` | `lotus:read` | The data sources, their types, and the default |
| `list_schemas`, `list_tables`, `describe_table` | `lotus:read` | Explore a source, within your visibility rules |
| `list_queries`, `get_query` | `lotus:read` | Saved queries, their statements, variables and charts |
| `list_dashboards`, `get_dashboard` | `lotus:read` | Dashboards, their cards and filters |
| `run_sql` | `lotus:query` | Run a read-only statement, a page of rows at a time |
| `get_column_values` | `lotus:query` | Up to 100 distinct values of a column |
| `run_query` | `lotus:query` | Run a saved query, with values for its variables |
| `run_dashboard` | `lotus:query` | Run a dashboard's query cards, with filter values |
| `save_query`, `update_query` | `lotus:write` | Save a statement, or change a saved query |
| `save_chart` | `lotus:write`, `lotus:query` | Set a saved query's chart, as Lotus Web shows it. It runs the query once to check the chart's fields |
| `create_dashboard`, `add_dashboard_card` | `lotus:write` | Build a dashboard of queries, charts, text and headings. A card with a chart also needs `lotus:query` |

Saved queries (`lotus://queries/{id}`) and dashboards
(`lotus://dashboards/{id}`) are also resources, which a client can attach
to a conversation.

What every tool keeps to:

- **Read-only.** Every statement runs with `read_only: true`, whatever
  `config :lotus, read_only:` says, so a write is refused by the same
  checks Lotus Web uses.
- **Your rules.** Statements and schema introspection go through your
  visibility rules, column policies and middleware, with the signed-in
  person as the actor (below). See "What read-only does not cover" for
  what those rules can and cannot stop.
- **Bounded.** A tool returns a page of rows (100 by default, at most
  `max_rows`); the client pages through larger results. Lists return
  the first 200 queries or dashboards, and `run_dashboard` runs at most
  50 query cards, one at a time.
- **Saved statements stay read-only.** `save_query` and `update_query`
  refuse a statement that writes, so a query saved over MCP cannot write
  later, even where Lotus Web runs with `read_only: false`.
- **Nothing deleted.** There is no tool that deletes a query, chart or
  dashboard. `update_query` and `save_chart` change existing records and
  say so (`destructiveHint`), so a client asks before calling them.

## Setup

### 1. Add Sake

`Lotus.MCP` compiles only when your app depends on Sake:

```elixir
# mix.exs
{:sake, "~> 0.4"}
```

Add `:sake` to the `import_deps` of your `.formatter.exs` if you write
Sake modules of your own. If `config :lotus, :mcp` is set but Sake isn't a
dependency, Lotus logs a warning when it starts.

### 2. Make your login the authorization server

Sake makes your app the OAuth 2.1 authorization server for its own MCP
endpoint: the person signs in with your app's login, sees a consent page,
and the client gets a token for them. See Sake's quickstart for the whole
setup; for Lotus it comes down to a subject module, the `Sake` child and
three router lines.

The subject module says who is signed in, and who may connect. To let
only admins in, and let analysts read and query but not write:

```elixir
defmodule MyApp.MCP.Subject do
  @behaviour Sake.Auth.Subject

  @impl true
  def from_conn(conn) do
    case conn.assigns[:current_user] do
      %{} = user -> {:ok, user}
      _ -> :error
    end
  end

  @impl true
  def id(user), do: to_string(user.id)
  @impl true
  def fetch(id), do: MyApp.Accounts.fetch_user(id)
  @impl true
  def display(user), do: user.email

  # Only staff may connect a client at all.
  @impl true
  def authorize_resource?(user, _resource), do: user.role in [:admin, :analyst]

  # Admins may also save; analysts read and query.
  @impl true
  def scopes_for(%{role: :admin}, _resource), do: :all
  def scopes_for(_user, _resource), do: ["lotus:read", "lotus:query"]
end
```

`fetch/1` runs on every request, so a person you remove or demote loses
access at once, not when their token expires.

```elixir
# application.ex
children = [
  # ...
  {Sake,
   secret_key_base: MyAppWeb.Endpoint.config(:secret_key_base),
   auth: [
     subject: MyApp.MCP.Subject,
     issuer: "https://myapp.example.com",
     servers: [Lotus.MCP],
     store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}
   ]},
  MyAppWeb.Endpoint
]
```

The Ecto store keeps tokens across restarts; it needs Sake's migration
(`Sake.Auth.Migration.up/0` in a migration of your own).

```elixir
# router.ex
import Sake.Router

scope "/" do
  sake_well_known()
end

scope "/oauth" do
  pipe_through :api
  sake_oauth_api()
end

scope "/oauth" do
  pipe_through [:browser, :require_authenticated_user]
  sake_oauth_authorize()
end

scope "/" do
  sake_endpoint "/lotus/mcp", server: Lotus.MCP, auth: true
end
```

Always serve `Lotus.MCP` with `auth: true` on a network. Without it there
is no token, Sake checks no scope, and anyone who reaches the URL gets
every tool.

### 3. Say who may use Lotus

Signing in to your app is not enough: your login may be your customers'
too. `Lotus.MCP` refuses everyone until you say who may use it, on every
request:

```elixir
# config/config.exs
config :lotus, :mcp, authorize: {MyApp.Accounts, :lotus_user?}

# MyApp.Accounts
def lotus_user?(user), do: user.role in [:admin, :analyst]
```

It receives the principal your subject module's `fetch/1` returned and
must return `true`. A refused person is shown no tools and no resources,
and cannot call any. Keep it in step with `authorize_resource?/2`, which
decides who may connect a client in the first place.

### 4. Connect Claude Code

```
claude mcp add --transport http lotus https://myapp.example.com/lotus/mcp
```

The first time Claude Code uses it, your browser opens on your app's
login, then the consent page. After that, ask away:

- *"What did signups look like last week?"* → `list_dashboards`, then `run_dashboard`
- *"Which plans churn most? Check the subscriptions table."* → `describe_table`, `run_sql`
- *"Save that as a query, chart it as a bar chart and put it on the Growth dashboard."* → `save_query`, `save_chart`, `add_dashboard_card`

Claude Code asks before each tool call until you allow it; allow the
`lotus:read` and `lotus:query` tools once and keep the write tools on ask.

## Configuration

```elixir
config :lotus, :mcp,
  authorize: {MyApp.Accounts, :lotus_user?},
  actor: {MyApp.Reporting, :lotus_actor},
  data_sources: ["analytics"],
  max_rows: 500
```

- **`:authorize`** (required) — who may use Lotus over MCP, above.
- **`:actor`** — what Lotus receives as `:context` and `:scope` for the
  signed-in principal: a `{module, function}` or a one-argument function
  that takes the principal (what your subject module's `fetch/1` returned)
  and returns `[context: ..., scope: ...]`, both keys always (a call
  fails rather than run without a scope). By default the principal is
  both. If you have a custom visibility resolver or middleware, return
  what they expect, as your Lotus Web resolver does:

  ```elixir
  def lotus_actor(user), do: [context: %{user_id: user.id}, scope: %{role: user.role}]
  ```

- **`:data_sources`** — only these data sources are listed, queried, or
  used by the saved queries and dashboards the tools run (default: all).
  Saved queries on other sources are not listed.
- **`:max_rows`** — the most rows a tool returns in one page (default 500).

What helps the model write good queries comes from Lotus itself, not
this setting. Describe each source with
`config :lotus, data_source_descriptions: %{"support" => "helpdesk tickets and agents"}`.
`list_data_sources` shows these descriptions. `describe_table` shows
foreign keys and column comments, and `list_tables` shows estimated row
counts. Database comments on the columns that matter are worth writing
(`COMMENT ON COLUMN tickets.status IS 'open, pending or solved'`).

## Mounting in your own MCP server

If your app has an MCP server of its own, mount Lotus in it instead, under
a prefix (its tools become `lotus_run_sql` and so on), with only the
parts you want:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"

  tools [MyApp.MCP.SearchOrders]
  mount Lotus.MCP, prefix: "lotus", except: [Lotus.MCP.Tools.UpdateQuery]
end
```

Serve `MyApp.MCP` on the endpoint and list it in the `Sake` child's
`servers:`. The `lotus:*` scopes come with the mount.

### Saying who may use Lotus from your server

Your server can say who may use Lotus and as which actor, instead of
`config :lotus, :mcp`, with the `Lotus.MCP.Host` middleware:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"

  mount Lotus.MCP, prefix: "lotus"

  middleware :before_request, [
    {Lotus.MCP.Host, authorize: {MyApp.Accounts, :lotus_user?},
                     actor: {MyApp.Reporting, :lotus_actor}}
  ]
end
```

`:authorize` and `:actor` mean what they mean in the config, above, and
take a `{module, function}`. `config :lotus, :mcp` still wins where it
sets the same key, so keep `:data_sources` and `:max_rows` there and leave
these two out of it. Lotus Web's `Lotus.Web.MCP` declares it with your
resolver, which is why a host serving it configures neither.

### Prompts of your own

Lotus ships no MCP prompts: it doesn't know what your data means. A
prompt is a named request a person picks in their client (Claude Code
lists them as slash commands), so it belongs to your app, about your own
saved queries and dashboards. Write one with `Sake.Prompt` in the server
that mounts Lotus:

```elixir
defmodule MyApp.MCP.Prompts.WeeklyRevenue do
  use Sake.Prompt,
    name: "weekly_revenue",
    description: "Summarize last week's revenue against the week before",
    scope: "lotus:query"

  arg :region, :string, description: "Only this region (optional)"

  @impl true
  def get(args, _ctx) do
    region = if args[:region], do: " for #{args[:region]}", else: ""

    {:ok,
     [user: "Run the Revenue dashboard#{region} for last week and the week before " <>
              "(run_dashboard), and summarize what changed and why it might have."]}
  end
end

defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  mount Lotus.MCP, prefix: "lotus"
  prompts [MyApp.MCP.Prompts.WeeklyRevenue]
end
```

A prompt only writes the request; the model then works through the
Lotus tools, so the person's scopes and `authorize:` apply as for
anything else they ask. Lotus's `authorize:` gate covers Lotus's own
tools and resources, not your server's components: give your prompts a
`scope:` and, if they need it, middleware of your own.

## Locally, over stdio

For a development database on your own machine, skip authorization and
run the server over stdio:

```
claude mcp add --transport stdio lotus -- mix sake.stdio Lotus.MCP
```

There is no token over stdio, so every tool is available and the
principal is `nil`; allow it in your dev config with
`config :lotus, :mcp, authorize: fn _ -> true end`. Use it only where
whoever runs the command may see all of the data.

## What read-only does not cover

The guarantees above are Lotus's, and an MCP client reaches them the way
Lotus Web does. Lotus checks the statements a model writes, but those
checks read SQL, not the database, so two limits remain:

- **Column policies match result column names.** Lotus refuses a
  statement that renames, wraps or filters on a protected column
  (`SELECT ssn AS s`, `upper(ssn)`, `WHERE ssn = ...`; see Column-Level
  Visibility in the visibility guide), but a view or function that
  renames the column inside the database gets past that. For a column
  that must never leave the database, use a table rule, a view without
  it, or a database role that cannot read it.
- **Functions run with the role's privileges.** A read-only run refuses
  the commands and functions known to have effects beyond it (`SET`,
  `set_config`, advisory locks, `pg_terminate_backend`, `dblink`, file
  access, `GET_LOCK` on MySQL), and on PostgreSQL rolls back instead of
  committing. A deny list is never complete, so point the data sources
  you expose over MCP at a database role with only `SELECT` grants (and
  no `pg_signal_backend`), ideally on a replica, not at the role your
  app writes with.

The `data_sources` setting is the simplest way to do the second: give
MCP a source of its own on a read-only role.

## Charts

`save_chart` and `add_dashboard_card` take the chart types Lotus Web
renders (`bar`, `line`, `area`, `pie`, `kpi`, `histogram` and the rest)
and the fields each one reads (`x_field`, `y_field`, `series_field`,
`value_field`, ...). Before saving, the query runs once for a single row,
and a field that is not a column of its result is refused with the
columns there are, so the chart that lands in Lotus Web renders.

## Testing your setup

Sake's test client talks to the server in memory, with a principal and
the scopes a role would hold:

```elixir
import Sake.Test

# config :lotus, :mcp, authorize: fn _ -> true end in config/test.exs
client = connect(Lotus.MCP, scope: analyst, scopes: ["lotus:read", "lotus:query"])
assert {:ok, %{structured: %{"rows" => _}}} =
         call_tool(client, "run_sql", %{"data_source" => "main", "statement" => "SELECT 1"})

assert {:error, {:insufficient_scope, _}} =
         call_tool(client, "save_query", %{"name" => "x", "statement" => "SELECT 1", "data_source" => "main"})
```

Call `Sake.Test.start()` in `test/test_helper.exs`: `run_sql`,
`run_query` and `run_dashboard` can run as tasks for a client that asks.
