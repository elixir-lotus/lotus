# Dashboards

Dashboards let you combine multiple queries into interactive, shareable views. They're ideal for building reporting interfaces, KPI displays, and data exploration tools.

## Overview

A dashboard consists of:

- **Cards** - Individual content blocks arranged in a grid
- **Filters** - Input controls that affect multiple cards simultaneously
- **Filter mappings** - Connections between filters and query variables

Every function in this guide is available both on the `Lotus` facade (used
throughout the examples) and on `Lotus.Dashboards`, which is where the full
documentation lives.

## Creating a Dashboard

```elixir
{:ok, dashboard} = Lotus.create_dashboard(%{
  name: "Sales Overview",
  description: "Key sales metrics and trends"
})
```

Dashboard names are unique across the install.

### Dashboard Settings

The `settings` field stores UI preferences as a map. Keys are normalized to
strings on write, so `%{theme: "dark"}` is stored as `%{"theme" => "dark"}`:

```elixir
Lotus.update_dashboard(dashboard, %{
  settings: %{
    "theme" => "dark",
    "columns" => 12
  }
})
```

### Auto-refresh

Enable periodic refresh by setting `auto_refresh_seconds`. The value must be
between 60 and 3600 seconds; anything else fails the changeset.

```elixir
Lotus.update_dashboard(dashboard, %{auto_refresh_seconds: 300})  # 5 minutes
```

### Listing Dashboards

```elixir
# All dashboards, ordered by name
Lotus.list_dashboards()

# Preload associations (`:cards`, `:filters`)
Lotus.list_dashboards(preload: [:cards])

# Case-insensitive search on the dashboard name
Lotus.list_dashboards_by(search: "sales")
Lotus.list_dashboards_by(search: "sales", preload: [:cards, :filters])
```

`list_dashboards_by/1` accepts `:search` and `:preload`. Both
`list_dashboards/1` and `list_dashboards_by/1` order by name.

### Fetching and Deleting

```elixir
Lotus.get_dashboard(id)   # => %Dashboard{} | nil
Lotus.get_dashboard!(id)  # raises Ecto.NoResultsError

{:ok, _} = Lotus.delete_dashboard(dashboard)
```

Deleting a dashboard cascades to its cards, filters, and filter mappings.

## Working with Cards

Cards are the building blocks of dashboards. Each card occupies a position in a 12-column grid.

### Card Types

| Type | Description | `query_id` |
|------|-------------|------------|
| `:query` | Displays results from a saved query | required |
| `:text` | Markdown text content | must be `nil` |
| `:heading` | Section header | must be `nil` |
| `:link` | Clickable link to external resource | must be `nil` |

### Adding a Query Card

```elixir
# First, get or create a query
{:ok, query} = Lotus.create_query(%{
  name: "Monthly Revenue",
  statement: "SELECT date_trunc('month', created_at) AS month, SUM(amount) AS revenue FROM orders GROUP BY 1"
})

# Add it to the dashboard
{:ok, card} = Lotus.create_dashboard_card(dashboard, %{
  card_type: :query,
  query_id: query.id,
  title: "Revenue by Month",
  position: 0,
  layout: %{x: 0, y: 0, w: 6, h: 4}
})
```

`create_dashboard_card/2` accepts a `%Dashboard{}` or a dashboard id.

### Layout System

Cards use a 12-column grid. `layout` is an embedded schema with these fields:

| Field | Meaning | Constraint | Default |
|-------|---------|------------|---------|
| `x` | Column position | `0..11` | `0` |
| `y` | Row position | `>= 0` | `0` |
| `w` | Width in columns | `1..12` | `6` |
| `h` | Height in rows | `>= 1` | `4` |

`x + w` must not exceed 12 — a card that extends beyond the grid is rejected
with a changeset error on `:w`.

```elixir
# Full-width card at top
%{x: 0, y: 0, w: 12, h: 3}

# Two half-width cards side by side
%{x: 0, y: 3, w: 6, h: 4}  # Left
%{x: 6, y: 3, w: 6, h: 4}  # Right
```

### Text, Heading, and Link Cards

Non-query cards store their payload in the `content` map (keys are normalized
to strings) and must leave `query_id` unset.

```elixir
# Add a section heading
{:ok, _} = Lotus.create_dashboard_card(dashboard, %{
  card_type: :heading,
  content: %{"text" => "Key Metrics"},
  position: 0,
  layout: %{x: 0, y: 0, w: 12, h: 1}
})

# Add explanatory text
{:ok, _} = Lotus.create_dashboard_card(dashboard, %{
  card_type: :text,
  content: %{"markdown" => "Revenue figures are **updated daily** at midnight UTC."},
  position: 1,
  layout: %{x: 0, y: 1, w: 12, h: 2}
})
```

### Listing and Fetching Cards

```elixir
# Ordered by position, then id
Lotus.list_dashboard_cards(dashboard)
Lotus.list_dashboard_cards(dashboard, preload: [:query, :filter_mappings])

Lotus.get_dashboard_card(card_id)                      # => %DashboardCard{} | nil
Lotus.get_dashboard_card(card_id, preload: [:query])
Lotus.get_dashboard_card!(card_id, preload: [:query])  # raises Ecto.NoResultsError
```

### Reordering Cards

Pass card ids in the order you want; each card's `position` becomes its index
in the list. The whole reorder runs in one transaction.

```elixir
:ok = Lotus.reorder_dashboard_cards(dashboard, [card3.id, card1.id, card2.id])
```

### Updating and Deleting Cards

```elixir
{:ok, card} = Lotus.update_dashboard_card(card, %{title: "Revenue Chart"})

{:ok, _} = Lotus.delete_dashboard_card(card)
{:error, :not_found} = Lotus.delete_dashboard_card(-1)
```

Deleting a card also deletes its filter mappings.

### Visualization Overrides

Query cards can override the query's default visualization:

```elixir
Lotus.update_dashboard_card(card, %{
  visualization_config: %{
    "type" => "bar",
    "x_field" => "month",
    "y_field" => "revenue"
  }
})
```

## Dashboard Filters

Filters provide input controls that affect multiple cards. When a user changes a filter value, it's passed to the mapped query variables.

### Filter Types and Widgets

A filter declares both a `filter_type` and a `widget`. Incompatible pairs are
rejected by the changeset:

| `filter_type` | Allowed `widget` values |
|---------------|-------------------------|
| `:text` | `:input`, `:select` |
| `:number` | `:input`, `:select` |
| `:date` | `:date_picker`, `:input` |
| `:date_range` | `:date_range_picker` |
| `:select` | `:select` |

A filter's `name` must be a valid identifier (`^[A-Za-z_][A-Za-z0-9_]*$`) and
unique within its dashboard. `label` is required. `default_value` is a string:
a concrete value, or a relative date token for a `:date` or `:date_range`
filter (see [Relative Date Tokens](#relative-date-tokens)).

### Creating Filters

```elixir
{:ok, date_filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "date_range",
  label: "Date Range",
  filter_type: :date_range,
  widget: :date_range_picker,
  default_value: "2024-01-01,2024-01-31",
  position: 0
})

{:ok, region_filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "region",
  label: "Region",
  filter_type: :select,
  widget: :select,
  config: %{
    "options" => [
      %{"value" => "us", "label" => "United States"},
      %{"value" => "eu", "label" => "Europe"},
      %{"value" => "apac", "label" => "Asia Pacific"}
    ]
  },
  position: 1
})
```

The `config` map holds widget-specific settings (select options, formats,
validation rules). Keys are normalized to strings.

### Listing, Updating, and Deleting Filters

```elixir
# Ordered by position, then id
Lotus.list_dashboard_filters(dashboard)

Lotus.get_dashboard_filter(id)   # => %DashboardFilter{} | nil
Lotus.get_dashboard_filter!(id)  # raises Ecto.NoResultsError

{:ok, filter} = Lotus.update_dashboard_filter(filter, %{label: "Period"})

{:ok, _} = Lotus.delete_dashboard_filter(filter)
{:error, :not_found} = Lotus.delete_dashboard_filter(-1)
```

### Mapping Filters to Query Variables

Connect filters to query variables using filter mappings. The variable name
must be a valid identifier, and each `(card, filter, variable_name)` triple is
unique.

```elixir
# Map date_range filter to the "start_date" variable in a card's query
Lotus.create_filter_mapping(card, date_filter, "start_date")

# Map region filter to "region" variable
Lotus.create_filter_mapping(card, region_filter, "region")
```

A single filter can map to different variable names across cards:

```elixir
# Same filter, different variable names per card
Lotus.create_filter_mapping(orders_card, date_filter, "order_date")
Lotus.create_filter_mapping(revenue_card, date_filter, "transaction_date")
```

Inspect and remove mappings:

```elixir
# Mappings for a card, with `:filter` preloaded
Lotus.list_card_filter_mappings(card)

{:ok, _} = Lotus.delete_filter_mapping(mapping)
{:error, :not_found} = Lotus.delete_filter_mapping(-1)
```

### Transform Configuration

A mapping can carry an optional `transform` map that reshapes the filter value
before it reaches the query variable. Lotus ships two transforms, both for
splitting a **comma-separated** date range:

| `"type"` | Effect |
|----------|--------|
| `"date_range_start"` | Takes the part before the comma |
| `"date_range_end"` | Takes the part after the comma; a value with no comma passes through unchanged |

Any other transform map is a no-op — the raw value is passed through.

```elixir
Lotus.create_filter_mapping(card, date_filter, "start_date",
  transform: %{"type" => "date_range_start"}
)

Lotus.create_filter_mapping(card, date_filter, "end_date",
  transform: %{"type" => "date_range_end"}
)
```

With the filter value `"2024-01-01,2024-03-31"`, the card's query receives
`start_date` = `"2024-01-01"` and `end_date` = `"2024-03-31"`.

### Relative Date Tokens

A filter value can be a relative date token in place of a concrete date. This
applies to the `default_value` of a filter and to a value in `:filter_values`.
Lotus resolves the token each time a card runs, so a dashboard with the default
`"last_30_days"` always shows the last 30 days.

| Token | Range on Monday 2026-09-14 |
|-------|----------------------------|
| `"today"` | 2026-09-14 to 2026-09-14 |
| `"yesterday"` | 2026-09-13 to 2026-09-13 |
| `"last_7_days"` | 2026-09-08 to 2026-09-14 |
| `"last_30_days"` | 2026-08-16 to 2026-09-14 |
| `"last_90_days"` | 2026-06-17 to 2026-09-14 |
| `"this_week"` | 2026-09-14 to 2026-09-20 |
| `"this_month"` | 2026-09-01 to 2026-09-30 |
| `"this_quarter"` | 2026-07-01 to 2026-09-30 |
| `"this_year"` | 2026-01-01 to 2026-12-31 |
| `"last_week"` | 2026-09-07 to 2026-09-13 |
| `"last_month"` | 2026-08-01 to 2026-08-31 |
| `"last_quarter"` | 2026-04-01 to 2026-06-30 |
| `"last_year"` | 2025-01-01 to 2025-12-31 |

- The `last_N_days` tokens include today.
- The week, month, quarter and year tokens cover the full calendar period, also
  the days after today.
- Weeks are ISO weeks and start on Monday.
- Today is the current date in UTC. All cards of one `run_dashboard/2` call use
  the same day.

The `filter_type` controls how a token resolves:

| `filter_type` | Tokens that resolve | Resolved value |
|---------------|---------------------|----------------|
| `:date_range` | all tokens | `"YYYY-MM-DD,YYYY-MM-DD"` |
| `:date` | `"today"`, `"yesterday"` | `"YYYY-MM-DD"` |
| `:text`, `:number`, `:select` | none | the value does not change |

A `:date` filter holds one day, so its changeset does not accept a range token
such as `"last_7_days"` as the `default_value`.

The resolved range of a `:date_range` filter is the value that the
`date_range_start` and `date_range_end` transforms split:

```elixir
{:ok, period_filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "period",
  label: "Period",
  filter_type: :date_range,
  widget: :date_range_picker,
  default_value: "last_30_days",
  position: 0
})

Lotus.create_filter_mapping(card, period_filter, "start_date",
  transform: %{"type" => "date_range_start"}
)

Lotus.create_filter_mapping(card, period_filter, "end_date",
  transform: %{"type" => "date_range_end"}
)
```

On 2026-09-14 the card's query receives `start_date` = `"2026-08-16"` and
`end_date` = `"2026-09-14"`.

`Lotus.list_relative_date_tokens/0` returns all tokens, for example to fill a
select in a filter UI. `Lotus.Dashboards.DateToken` resolves tokens outside a
dashboard run.

### Cascading Filters

A select filter can get its options from a saved query, and the options of one
filter can depend on the value of another filter. For example, a `city`
dropdown can show only the cities of the selected `country`.

Two optional fields set this up:

- `source_query_id` — a saved query that gives the options. The filter must use
  the `:select` widget.
- `depends_on_filter_id` — another filter of the same dashboard. Its value goes
  to the source query as the variable named after that filter's `name`. A
  filter with a dependency needs a `source_query_id`.

```elixir
{:ok, countries} = Lotus.create_query(%{
  name: "Countries",
  statement: "SELECT code, name FROM countries ORDER BY name"
})

{:ok, cities} = Lotus.create_query(%{
  name: "Cities by country",
  statement: "SELECT DISTINCT city FROM locations WHERE country = {{country}} ORDER BY city"
})

{:ok, country_filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "country",
  label: "Country",
  filter_type: :select,
  widget: :select,
  source_query_id: countries.id,
  position: 0
})

{:ok, city_filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "city",
  label: "City",
  filter_type: :select,
  widget: :select,
  source_query_id: cities.id,
  depends_on_filter_id: country_filter.id,
  position: 1
})

Lotus.list_dashboard_filter_options(country_filter)
# => {:ok, [%{value: "PT", label: "Portugal"}, %{value: "US", label: "United States"}]}

Lotus.list_dashboard_filter_options(city_filter, filter_values: %{"country" => "PT"})
# => {:ok, [%{value: "Lisbon", label: "Lisbon"}, %{value: "Porto", label: "Porto"}]}
```

`Lotus.list_dashboard_filter_options/2` works for every filter:

| Filter | Options |
|--------|---------|
| No `source_query_id` | The static options under `"options"` in `config` (`[]` when there are none) |
| `source_query_id`, no dependency | One option for each row of the source query |
| `source_query_id` and a dependency with a value | One option for each row, with the value of the other filter as a variable |
| `source_query_id` and a dependency with no value | `[]`, and the source query does not run |

The first column of a row is the value and the second column is the label. A
query with one column uses that column for both. The value of the other filter
comes from `:filter_values`, or else from its `default_value`, and a relative
date token resolves first. Other options, such as `:context`, `:scope` and
`:cache`, go to `Lotus.run_query/2`. An error from the source query comes back
unchanged.

Lotus does not fetch the options again by itself. Call
`list_dashboard_filter_options/2` again when the value of the other filter
changes. `run_dashboard/2` does not check the value of a filter against its
options.

`Lotus.create_dashboard_filter/3` and `Lotus.update_dashboard_filter/3` reject:

- a `source_query_id` on a filter without the `:select` widget
- a `depends_on_filter_id` with no `source_query_id`
- a dependency on the filter itself, on a filter of another dashboard, or a
  dependency that makes a cycle (`country` → `city` → `country`)

Two updates at the same time can still make a cycle. The options of a filter
use only the filter it depends on, so a cycle cannot make them loop.

Deleting the source query sets `source_query_id` to `nil`, and the filter then
returns its static options. Deleting the other filter sets
`depends_on_filter_id` to `nil`.

## Running Dashboards

Execute all query cards in a dashboard with a single call. `run_dashboard/2`
returns a **plain map** of card id to result — it is not wrapped in an `:ok`
tuple, because individual cards succeed or fail independently:

```elixir
results = Lotus.run_dashboard(dashboard)
# => %{
#      1 => {:ok, %Lotus.Result{}},
#      2 => {:error, "Missing required variable: status"}
#    }
```

Non-query cards (`:text`, `:heading`, `:link`) are skipped and do not appear in
the map.

### With Filter Values

Pass current filter values to override the filters' `default_value`. Keys are
filter **names**:

```elixir
results = Lotus.run_dashboard(dashboard,
  filter_values: %{
    "date_range" => "2024-01-01,2024-03-31",
    "region" => "us"
  }
)
```

### Execution Options

| Option | Description |
|--------|-------------|
| `:filter_values` | Map of filter name to value (default: `%{}`) |
| `:parallel` | Run cards concurrently (default: `true`) |
| `:timeout` | Per-card timeout in milliseconds (default: `30_000`) |

Any other option is forwarded to `Lotus.run_query/2`, so `:search_path`,
`:cache`, and `:scope` work here too. A card that exceeds `:timeout` yields
`{:error, :timeout}`; a card that raises yields `{:error, message}`.

### Running Individual Cards

```elixir
{:ok, result} = Lotus.run_dashboard_card(card, filter_values: %{"region" => "eu"})

# A non-query card
{:error, :not_a_query_card} = Lotus.run_dashboard_card(text_card)

# An unknown card id
{:error, :not_found} = Lotus.run_dashboard_card(-1)
```

`run_dashboard_card/2` takes `:filter_values` plus any `Lotus.run_query/2`
option.

## Public Sharing

Share dashboards via secure public links. The token is 32 random bytes,
URL-safe Base64 encoded.

### Enable Sharing

```elixir
{:ok, dashboard} = Lotus.enable_public_sharing(dashboard)
dashboard.public_token
# => "k3F1...q8"
```

Each call generates a fresh token, so calling it again on an already-shared
dashboard rotates the link and invalidates the old one.

### Access by Token

```elixir
case Lotus.get_dashboard_by_token(token) do
  nil -> :not_found
  dashboard -> Lotus.run_dashboard(dashboard)
end
```

### Disable Sharing

```elixir
{:ok, dashboard} = Lotus.disable_public_sharing(dashboard)
dashboard.public_token
# => nil
```

Disabling clears the token, so any link already handed out stops working.

## Exporting Dashboards

Export all query-card results to a ZIP archive with one CSV per card. This
lives on `Lotus.Export`, not on the `Lotus` facade:

```elixir
{:ok, zip_binary} = Lotus.Export.export_dashboard(dashboard,
  filter_values: %{"region" => "us"}
)

File.write!("sales_report.zip", zip_binary)
```

The archive contains:

- `manifest.json` — dashboard metadata and per-card status
- one `<slugified_card_title>.csv` per successful query card (`card_<id>.csv`
  when the card has no title)
- `<name>.csv.error.txt` for any card that failed, holding the error

`export_dashboard/2` accepts `:filter_values` plus any `Lotus.run_query/2`
option.

## Database Migration

Dashboard tables are created by migration V3, which is part of the standard
Lotus migration chain:

```elixir
defmodule MyApp.Repo.Migrations.CreateLotusTables do
  use Ecto.Migration

  def up, do: Lotus.Migrations.up()
  def down, do: Lotus.Migrations.down()
end
```

This creates:

- `lotus_dashboards`
- `lotus_dashboard_cards`
- `lotus_dashboard_filters`
- `lotus_dashboard_card_filter_mappings`

Migration V6 adds `source_query_id` and `depends_on_filter_id` to
`lotus_dashboard_filters` for [Cascading Filters](#cascading-filters).

**Postgres:** `mix ecto.migrate` applies it (`Lotus.Migrations.Postgres.V6`).

**MySQL and SQLite:** these migrations have no versions. A fresh install gets
the columns. An existing install must run this SQL by hand before it deploys the
new Lotus version, because Lotus reads every column of a filter:

```sql
-- MySQL
ALTER TABLE lotus_dashboard_filters
  ADD COLUMN source_query_id BIGINT UNSIGNED NULL,
  ADD COLUMN depends_on_filter_id BIGINT UNSIGNED NULL,
  ADD CONSTRAINT lotus_dashboard_filters_source_query_id_fkey
    FOREIGN KEY (source_query_id) REFERENCES lotus_queries (id) ON DELETE SET NULL,
  ADD CONSTRAINT lotus_dashboard_filters_depends_on_filter_id_fkey
    FOREIGN KEY (depends_on_filter_id) REFERENCES lotus_dashboard_filters (id) ON DELETE SET NULL;

CREATE INDEX lotus_dashboard_filters_source_query_id_index
  ON lotus_dashboard_filters (source_query_id);
CREATE INDEX lotus_dashboard_filters_depends_on_filter_id_index
  ON lotus_dashboard_filters (depends_on_filter_id);

-- SQLite
ALTER TABLE lotus_dashboard_filters ADD COLUMN source_query_id INTEGER
  CONSTRAINT lotus_dashboard_filters_source_query_id_fkey
  REFERENCES lotus_queries (id) ON DELETE SET NULL;
ALTER TABLE lotus_dashboard_filters ADD COLUMN depends_on_filter_id INTEGER
  CONSTRAINT lotus_dashboard_filters_depends_on_filter_id_fkey
  REFERENCES lotus_dashboard_filters (id) ON DELETE SET NULL;

CREATE INDEX lotus_dashboard_filters_source_query_id_index
  ON lotus_dashboard_filters (source_query_id);
CREATE INDEX lotus_dashboard_filters_depends_on_filter_id_index
  ON lotus_dashboard_filters (depends_on_filter_id);
```

## Example: Sales Dashboard

```elixir
# Create dashboard
{:ok, dashboard} = Lotus.create_dashboard(%{
  name: "Sales Dashboard",
  description: "Daily sales metrics"
})

# Add date filter
{:ok, date_filter} = Lotus.create_dashboard_filter(dashboard, %{
  name: "period",
  label: "Time Period",
  filter_type: :date_range,
  widget: :date_range_picker,
  position: 0
})

# Create queries
{:ok, revenue_query} = Lotus.create_query(%{
  name: "Daily Revenue",
  statement: """
  SELECT date, SUM(amount) AS revenue
  FROM orders
  WHERE date BETWEEN {{start_date}} AND {{end_date}}
  GROUP BY date
  """
})

{:ok, orders_query} = Lotus.create_query(%{
  name: "Order Count",
  statement: """
  SELECT COUNT(*) AS total
  FROM orders
  WHERE created_at BETWEEN {{from}} AND {{to}}
  """
})

# Add cards
{:ok, revenue_card} = Lotus.create_dashboard_card(dashboard, %{
  card_type: :query,
  query_id: revenue_query.id,
  title: "Revenue Trend",
  position: 0,
  layout: %{x: 0, y: 0, w: 8, h: 4}
})

{:ok, orders_card} = Lotus.create_dashboard_card(dashboard, %{
  card_type: :query,
  query_id: orders_query.id,
  title: "Total Orders",
  position: 1,
  layout: %{x: 8, y: 0, w: 4, h: 4}
})

# Map the one filter to both cards (with different variable names)
Lotus.create_filter_mapping(revenue_card, date_filter, "start_date",
  transform: %{"type" => "date_range_start"}
)
Lotus.create_filter_mapping(revenue_card, date_filter, "end_date",
  transform: %{"type" => "date_range_end"}
)

Lotus.create_filter_mapping(orders_card, date_filter, "from",
  transform: %{"type" => "date_range_start"}
)
Lotus.create_filter_mapping(orders_card, date_filter, "to",
  transform: %{"type" => "date_range_end"}
)

# Run the dashboard — note the bare map return
results = Lotus.run_dashboard(dashboard,
  filter_values: %{"period" => "2024-01-01,2024-01-31"}
)

for {card_id, outcome} <- results do
  case outcome do
    {:ok, %Lotus.Result{rows: rows}} -> IO.puts("card #{card_id}: #{length(rows)} rows")
    {:error, reason} -> IO.puts("card #{card_id} failed: #{inspect(reason)}")
  end
end
```
