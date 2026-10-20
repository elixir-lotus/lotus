# Security

## Reporting a vulnerability

Do not open a public issue for a security problem. Report it privately
through GitHub: [Report a vulnerability](https://github.com/elixir-lotus/lotus/security/advisories/new).

Say what an attacker can do, and how: the data source and adapter, the
configuration (read-only, visibility rules, resolver), the statement, the
variable values or the prompt, and the steps. We answer within a week,
agree on a fix and a date, and credit you in the advisory unless you ask
us not to.

A problem in the Lotus Web UI goes to
[lotus_web](https://github.com/elixir-lotus/lotus_web/security/advisories/new).
If you are not sure which one it belongs to, report it here.

## Supported versions

Security fixes are made to the latest release. A fix is not backported to
an earlier minor version.

## What is in scope

Lotus runs SQL (and other query languages, through source adapters)
against your app's databases, on behalf of the people you let use it. A
problem is in scope when a statement, a variable value, an AI prompt or an
MCP call can:

- **write despite read-only.** Change data, schema or session state, or
  run a function with effects beyond the query, while `read_only: true`
  (the default) is in force, or through a saved query that was accepted
  as read-only.
- **get past visibility rules.** Read a schema, table or column that the
  schema, table or column rules (or a `Lotus.Visibility.Resolver`) deny,
  or a source that `source_visible?/2` hides, through execution,
  discovery, the cache or a renamed or wrapped column.
- **inject SQL through a variable.** A `{{var}}` value, or a `[[...]]`
  optional block, ends up in the statement as SQL instead of a bound
  parameter.
- **turn AI query generation against its rules.** Generated or explained
  queries reveal what visibility hides, or an untrusted adapter's
  `ai_context` gets past the `:trusted_source_adapters` boundary.
- **misuse `Lotus.MCP`.** A client reaches tools or resources without
  passing `authorize`, beyond the scopes it was granted, or as another
  person.
- **leak credentials.** Database URLs or passwords, AI provider API keys
  or OAuth tokens show up in results, errors, logs, telemetry, the cache
  or an LLM prompt.
- **exhaust the server.** Make the app or the database do unbounded work
  past the limits Lotus sets.

Some limits are documented and are not vulnerabilities on their own: a
view or function inside the database that renames a protected column,
functions run with the privileges of the database role, and sources
opted in with `allow_unrestricted_resources` (see the
[visibility](guides/visibility.md) and [MCP](guides/mcp.md) guides). For
data that must never leave the database, give Lotus a database role with
only `SELECT` grants, ideally on a read-only replica (see the
[configuration guide](guides/configuration.md)). Who may use Lotus at all,
and which scope a request runs with, is the app's job.
