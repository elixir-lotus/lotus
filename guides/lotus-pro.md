# Lotus Pro

Lotus and Lotus Web are MIT-licensed and complete: one person running their
own app gets everything they need from them, for good. Lotus Pro is a
commercial package for what a team or a company needs on top: people and
roles, who may see which data, sharing, an audit trail, workflows and a
governed AI data agent.

This page lists what Pro adds, and the rules that decide what is free and
what is paid.

## What stays free, and why

Three rules decide where a feature goes. They don't change from release to
release.

1. **Pro is for a buyer, not a user.** A feature that one person needs for
   themselves is free. A feature that only makes sense for a team or a
   company (people, roles, sharing, approval, audit) is Pro.
2. **A free feature stays free.** Nothing released in Lotus or Lotus Web
   moves to Pro later.
3. **Hooks are free, products are paid.** Every extension point Pro uses
   (middleware, resolvers, adapters, delivery channels, alert conditions,
   schedule targets, Lotus Web's authorization and slots) is public and
   documented. Your app can build on the same hooks. Pro is a finished
   product on top of them, not a key that unlocks them.

So the free editions include, among the rest:

- the SQL editor, schema browser, saved queries, variables and results
- dashboards, with filters, auto-refresh and public links
- schedules and alerts, delivered by email, Slack (incoming webhook) and
  webhook, as CSV, HTML or JSON
- the AI assistant (generate, explain and optimise queries) and the MCP
  server
- visibility rules and column masking, read-only execution and preflight
  checks
- middleware, caching, telemetry, and every source adapter

## Pro Teams

One company using Lotus inside its own app. It runs on Lotus v2 and Lotus
Web v2.

### People and access

- **Members and roles.** Whoever your app lets into Lotus is a member of the
  workspace, as Viewer, Editor, Admin, Owner or a role the workspace makes.
  Your app keeps deciding who gets in; Pro decides what they may do.
- **Data access per source.** A source is open to the workspace until an
  owner restricts it to the people and teams it is shared with. Rules hide
  schemas, tables and columns, mask values, and limit how many queries
  someone runs, for everyone, a role or one member.
- **Enforced everywhere.** The editor, dashboards, exports, schedules, the AI
  assistant, the AI agent and MCP all go through the same checks, on a cache
  hit too.
- **Admin pages** for members and roles, data access and settings, inside
  Lotus Web.

### Content

- **Owners and private content.** What someone saves is theirs, and shown as
  theirs ("Created by Ana"). They keep it shared with the workspace, make it
  private, or share it with people and teams, to view or to edit.
- **Folders** that nest, with access inherited down the tree.
- **Public links** that expire, open with a password, and keep their charts
  from being downloaded.

### Workflows

Saved queries, SQL steps and transforms chained on a canvas, each step's
results feeding the next. A workflow runs as the person who runs it, on a
schedule, or as a tool of the AI agent and MCP clients, and its output
downloads as CSV.

### AI

- **The AI data agent.** It investigates a question that takes more than one
  query ("why did revenue drop last week?") step by step: it reads the
  schema and the workflows the person may open, runs read-only queries as
  them, and stops with a summary that cites each step. Every step goes
  through their data access, masking, guardrails and audit, within a budget
  of steps, tokens and time. An investigation can be saved as a workflow.
- **AI governance.** Choose who may use the assistant, give it instructions
  about the workspace, and cap the tokens and requests each person, role or
  team may use per day, week or month.

### Audit

Every statement run (refused or not), change, export, share-link view, AI
request and MCP call, and every change to roles and access: who did it, from
where, and whether it was allowed. Admins search it and export it as CSV.

### Your product, your language

- **Branding:** your product's name, logo, favicon, colours, font, corners
  and AI assistant's name across Lotus.
- **Languages:** Pro's pages in English and French, and in any language your
  app adds.
- **Settings in the app:** admins change Lotus's settings and connect data
  sources from the app, with credentials kept encrypted.

## Coming later

- **Pro + Tenants**, for a SaaS app giving its own customers reports and
  dashboards: tenants for content, policies, theme and cache; row-level
  security per tenant; a tenant's own database.
- **Enterprise**: any number of applications, invoicing, and support with
  service levels.

## Licensing

Lotus Pro is a private package in the `lotus` organization on Hex, under the
Lotus Pro Commercial License. It is licensed per application, on any number
of servers, for any number of users and data sources. There is no license
key and nothing checks in at run time.
