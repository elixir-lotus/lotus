defmodule Lotus.Dashboards do
  @moduledoc """
  Service functions for managing dashboards in Lotus.

  Provides CRUD operations for dashboards, cards, filters, and filter mappings,
  as well as execution functions for running all cards in a dashboard.

  ## Dashboard Structure

  Dashboards contain:
  - **Cards** - Query results, text, links, or headings arranged in a 12-column grid
  - **Filters** - User inputs that control query variables across multiple cards
  - **Filter Mappings** - Connections between dashboard filters and card query variables

  ## Execution

  Use `run_dashboard/2` to execute all query cards in a dashboard simultaneously.
  Filter values are resolved and passed to each card's query variables via the
  configured mappings.

  ## Content changes

  Every function that creates, updates or deletes a dashboard, a card, a filter
  or a filter mapping takes `opts` with a `:context`, opaque caller data such as
  the current user, and fires the `:before_content_change` and
  `:after_content_change` middleware. So does `reorder_dashboard_cards/3`,
  which fires an `:update` for each card it moves, and so do
  `enable_public_sharing/2` and `disable_public_sharing/2`, which fire
  `:enable_sharing` and `:disable_sharing`. A plug that halts makes the function
  return `{:error, {:halted, reason}}` and nothing is written.

  A delete fires an event only for the record it names. Deleting a dashboard
  also deletes its cards, its filters and their filter mappings, and deleting a
  card or a filter also deletes its filter mappings, with no event for those.
  See `Lotus.Middleware`.
  """

  import Ecto.Query

  import Lotus.Helpers, only: [escape_like: 1]

  alias Lotus.Middleware

  alias Lotus.Storage.{
    Dashboard,
    DashboardCard,
    DashboardCardFilterMapping,
    DashboardFilter,
    Mutation
  }

  @type id :: integer() | binary()
  @type attrs :: map()

  # ── Dashboard CRUD ─────────────────────────────────────────────────────────

  @doc """
  Lists all dashboards.

  Returns dashboards ordered by name.

  ## Options

    * `:preload` - A list of associations to preload (e.g., `[:cards]`)

  ## Examples

      iex> list_dashboards()
      [%Dashboard{}, ...]

      iex> list_dashboards(preload: [:cards])
      [%Dashboard{cards: [%DashboardCard{}, ...]}, ...]

  """
  @spec list_dashboards(keyword()) :: [Dashboard.t()]
  def list_dashboards(opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(d in Dashboard, order_by: [asc: d.name], preload: ^preloads)
    |> Lotus.repo().all()
  end

  @doc """
  Lists dashboards with optional filtering.

  ## Options

    * `:search` - Search term to match against dashboard names (case insensitive)
    * `:preload` - A list of associations to preload (e.g., `[:cards]`)

  ## Examples

      iex> list_dashboards_by(search: "sales")
      [%Dashboard{name: "Sales Overview"}, ...]

      iex> list_dashboards_by(search: "sales", preload: [:cards])
      [%Dashboard{name: "Sales Overview", cards: [...]}, ...]

  """
  @spec list_dashboards_by(keyword()) :: [Dashboard.t()]
  def list_dashboards_by(opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])
    q = from(d in Dashboard, order_by: [asc: d.name], preload: ^preloads)

    q =
      case Keyword.get(opts, :search) do
        nil ->
          q

        term ->
          escaped = escape_like(term)
          from(d in q, where: ilike(d.name, ^"%#{escaped}%"))
      end

    Lotus.repo().all(q)
  end

  @doc """
  Gets a single dashboard by ID.

  Returns `nil` if the dashboard does not exist.
  """
  @spec get_dashboard(id()) :: Dashboard.t() | nil
  def get_dashboard(id) do
    Lotus.repo().get(Dashboard, id)
  end

  @doc """
  Gets a single dashboard by ID.

  Raises `Ecto.NoResultsError` if the dashboard does not exist.
  """
  @spec get_dashboard!(id()) :: Dashboard.t() | no_return()
  def get_dashboard!(id) do
    Lotus.repo().get!(Dashboard, id)
  end

  @doc """
  Gets a dashboard by its public sharing token.

  Returns `nil` if no dashboard has the given token.
  """
  @spec get_dashboard_by_token(String.t()) :: Dashboard.t() | nil
  def get_dashboard_by_token(token) when is_binary(token) do
    from(d in Dashboard, where: d.public_token == ^token)
    |> Lotus.repo().one()
  end

  @doc """
  Creates a new dashboard.

  ## Examples

      iex> create_dashboard(%{name: "Sales Dashboard"})
      {:ok, %Dashboard{}}

      iex> create_dashboard(%{})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_dashboard(attrs(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def create_dashboard(attrs, opts \\ []) do
    attrs
    |> Dashboard.new()
    |> Mutation.run(:create, :dashboard, opts)
  end

  @doc """
  Updates a dashboard.

  ## Examples

      iex> update_dashboard(dashboard, %{name: "New Name"})
      {:ok, %Dashboard{}}

  """
  @spec update_dashboard(Dashboard.t(), attrs(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def update_dashboard(%Dashboard{} = dashboard, attrs, opts \\ []) do
    dashboard
    |> Dashboard.update(attrs)
    |> Mutation.run(:update, :dashboard, opts)
  end

  @doc """
  Deletes a dashboard.

  Also deletes all associated cards, filters, and filter mappings.

  ## Examples

      iex> delete_dashboard(dashboard)
      {:ok, %Dashboard{}}

  """
  @spec delete_dashboard(Dashboard.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def delete_dashboard(%Dashboard{} = dashboard, opts \\ []) do
    Mutation.run(dashboard, :delete, :dashboard, opts)
  end

  @doc """
  Enables public sharing for a dashboard by generating a unique token.

  The token can be used to access the dashboard without authentication
  via `get_dashboard_by_token/1`.

  ## Examples

      iex> enable_public_sharing(dashboard)
      {:ok, %Dashboard{public_token: "abc123..."}}

  """
  @spec enable_public_sharing(Dashboard.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def enable_public_sharing(%Dashboard{} = dashboard, opts \\ []) do
    dashboard
    |> Dashboard.update(%{public_token: generate_secure_token()})
    |> Mutation.run(:enable_sharing, :dashboard, opts)
  end

  @doc """
  Disables public sharing for a dashboard by removing its token.

  ## Examples

      iex> disable_public_sharing(dashboard)
      {:ok, %Dashboard{public_token: nil}}

  """
  @spec disable_public_sharing(Dashboard.t(), keyword()) ::
          {:ok, Dashboard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def disable_public_sharing(%Dashboard{} = dashboard, opts \\ []) do
    dashboard
    |> Dashboard.update(%{public_token: nil})
    |> Mutation.run(:disable_sharing, :dashboard, opts)
  end

  defp generate_secure_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  # ── Card CRUD ──────────────────────────────────────────────────────────────

  @doc """
  Lists all cards for a dashboard.

  Returns cards ordered by position, then by id.

  ## Options

    * `:preload` - A list of associations to preload (e.g., `[:query, :filter_mappings]`)

  ## Examples

      iex> list_dashboard_cards(dashboard)
      [%DashboardCard{}, ...]

      iex> list_dashboard_cards(dashboard_id, preload: [:query, :filter_mappings])
      [%DashboardCard{query: %Query{}, filter_mappings: [...]}, ...]

  """
  @spec list_dashboard_cards(Dashboard.t() | id(), keyword()) :: [DashboardCard.t()]
  def list_dashboard_cards(dashboard_or_id, opts \\ [])

  def list_dashboard_cards(%Dashboard{id: id}, opts), do: list_dashboard_cards(id, opts)

  def list_dashboard_cards(dashboard_id, opts) do
    preloads = Keyword.get(opts, :preload, [])

    from(c in DashboardCard,
      where: c.dashboard_id == ^dashboard_id,
      order_by: [asc: c.position, asc: c.id],
      preload: ^preloads
    )
    |> Lotus.repo().all()
  end

  @doc """
  Gets a single card by ID.

  Returns `nil` if the card does not exist.

  ## Options

    * `:preload` - A list of associations to preload

  """
  @spec get_dashboard_card(id(), keyword()) :: DashboardCard.t() | nil
  def get_dashboard_card(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(c in DashboardCard, where: c.id == ^id, preload: ^preloads)
    |> Lotus.repo().one()
  end

  @doc """
  Gets a single card by ID.

  Raises `Ecto.NoResultsError` if the card does not exist.

  ## Options

    * `:preload` - A list of associations to preload

  """
  @spec get_dashboard_card!(id(), keyword()) :: DashboardCard.t() | no_return()
  def get_dashboard_card!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(c in DashboardCard, where: c.id == ^id, preload: ^preloads)
    |> Lotus.repo().one!()
  end

  @doc """
  Creates a new card for a dashboard.

  ## Examples

      iex> create_dashboard_card(dashboard, %{
      ...>   card_type: :query,
      ...>   query_id: 123,
      ...>   position: 0,
      ...>   layout: %{x: 0, y: 0, w: 6, h: 4}
      ...> })
      {:ok, %DashboardCard{}}

  """
  @spec create_dashboard_card(Dashboard.t() | id(), attrs(), keyword()) ::
          {:ok, DashboardCard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def create_dashboard_card(dashboard_or_id, attrs, opts \\ [])

  def create_dashboard_card(%Dashboard{id: id}, attrs, opts),
    do: create_dashboard_card(id, attrs, opts)

  def create_dashboard_card(dashboard_id, attrs, opts) do
    attrs
    |> Map.put(:dashboard_id, dashboard_id)
    |> DashboardCard.new()
    |> Mutation.run(:create, :dashboard_card, opts)
  end

  @doc """
  Updates a card.

  ## Examples

      iex> update_dashboard_card(card, %{title: "Revenue Chart"})
      {:ok, %DashboardCard{}}

  """
  @spec update_dashboard_card(DashboardCard.t(), attrs(), keyword()) ::
          {:ok, DashboardCard.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def update_dashboard_card(%DashboardCard{} = card, attrs, opts \\ []) do
    card
    |> DashboardCard.update(attrs)
    |> Mutation.run(:update, :dashboard_card, opts)
  end

  @doc """
  Deletes a card.

  Also deletes all associated filter mappings.
  """
  @spec delete_dashboard_card(DashboardCard.t() | id(), keyword()) ::
          {:ok, DashboardCard.t()}
          | {:error, Ecto.Changeset.t() | :not_found | Middleware.halted()}
  def delete_dashboard_card(card_or_id, opts \\ [])

  def delete_dashboard_card(%DashboardCard{} = card, opts),
    do: Mutation.run(card, :delete, :dashboard_card, opts)

  def delete_dashboard_card(id, opts) do
    case Lotus.repo().get(DashboardCard, id) do
      nil -> {:error, :not_found}
      card -> delete_dashboard_card(card, opts)
    end
  end

  @doc """
  Reorders cards in a dashboard.

  Accepts a list of card IDs in the desired order. Each card's position
  will be updated to match its index in the list. IDs of cards that belong
  to another dashboard are ignored.

  Each card whose position changes is an `:update` of `:dashboard_card`. Every
  `:before_content_change` runs before any position is written, so a halt on
  one card leaves every position as it was. The positions are written in one
  transaction.

  ## Options

    * `:context` - Opaque caller data passed to the content change middleware

  ## Examples

      iex> reorder_dashboard_cards(dashboard, [card3_id, card1_id, card2_id])
      :ok

  """
  @spec reorder_dashboard_cards(Dashboard.t() | id(), [id()], keyword()) ::
          :ok | {:error, Ecto.Changeset.t() | Middleware.halted() | term()}
  def reorder_dashboard_cards(dashboard_or_id, card_ids, opts \\ [])

  def reorder_dashboard_cards(%Dashboard{id: id}, card_ids, opts),
    do: reorder_dashboard_cards(id, card_ids, opts)

  def reorder_dashboard_cards(dashboard_id, card_ids, opts) when is_list(card_ids) do
    positions =
      card_ids
      |> Enum.with_index()
      |> Map.new(fn {card_id, position} -> {to_string(card_id), position} end)

    moves =
      from(c in DashboardCard, where: c.dashboard_id == ^dashboard_id and c.id in ^card_ids)
      |> Lotus.repo().all()
      |> Enum.map(&{&1, Map.fetch!(positions, to_string(&1.id))})
      |> Enum.reject(fn {card, position} -> card.position == position end)
      |> Enum.sort_by(fn {_card, position} -> position end)
      |> Enum.map(fn {card, position} ->
        {Ecto.Changeset.change(card, position: position), :update, :dashboard_card}
      end)

    case Mutation.run_all(moves, opts) do
      {:ok, _cards} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # ── Filter CRUD ────────────────────────────────────────────────────────────

  @doc """
  Lists all filters for a dashboard.

  Returns filters ordered by position, then by id.
  """
  @spec list_dashboard_filters(Dashboard.t() | id()) :: [DashboardFilter.t()]
  def list_dashboard_filters(%Dashboard{id: id}), do: list_dashboard_filters(id)

  def list_dashboard_filters(dashboard_id) do
    from(f in DashboardFilter,
      where: f.dashboard_id == ^dashboard_id,
      order_by: [asc: f.position, asc: f.id]
    )
    |> Lotus.repo().all()
  end

  @doc """
  Gets a single filter by ID.

  Returns `nil` if the filter does not exist.
  """
  @spec get_dashboard_filter(id()) :: DashboardFilter.t() | nil
  def get_dashboard_filter(id) do
    Lotus.repo().get(DashboardFilter, id)
  end

  @doc """
  Gets a single filter by ID.

  Raises `Ecto.NoResultsError` if the filter does not exist.
  """
  @spec get_dashboard_filter!(id()) :: DashboardFilter.t() | no_return()
  def get_dashboard_filter!(id) do
    Lotus.repo().get!(DashboardFilter, id)
  end

  @doc """
  Creates a new filter for a dashboard.

  ## Examples

      iex> create_dashboard_filter(dashboard, %{
      ...>   name: "date_range",
      ...>   label: "Date Range",
      ...>   filter_type: :date_range,
      ...>   widget: :date_range_picker,
      ...>   position: 0
      ...> })
      {:ok, %DashboardFilter{}}

  """
  @spec create_dashboard_filter(Dashboard.t() | id(), attrs(), keyword()) ::
          {:ok, DashboardFilter.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def create_dashboard_filter(dashboard_or_id, attrs, opts \\ [])

  def create_dashboard_filter(%Dashboard{id: id}, attrs, opts),
    do: create_dashboard_filter(id, attrs, opts)

  def create_dashboard_filter(dashboard_id, attrs, opts) do
    attrs
    |> Map.put(:dashboard_id, dashboard_id)
    |> DashboardFilter.new()
    |> Mutation.run(:create, :dashboard_filter, opts)
  end

  @doc """
  Updates a filter.

  ## Examples

      iex> update_dashboard_filter(filter, %{label: "Select Period"})
      {:ok, %DashboardFilter{}}

  """
  @spec update_dashboard_filter(DashboardFilter.t(), attrs(), keyword()) ::
          {:ok, DashboardFilter.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def update_dashboard_filter(%DashboardFilter{} = filter, attrs, opts \\ []) do
    filter
    |> DashboardFilter.update(attrs)
    |> Mutation.run(:update, :dashboard_filter, opts)
  end

  @doc """
  Deletes a filter.

  Also deletes all associated filter mappings.
  """
  @spec delete_dashboard_filter(DashboardFilter.t() | id(), keyword()) ::
          {:ok, DashboardFilter.t()}
          | {:error, Ecto.Changeset.t() | :not_found | Middleware.halted()}
  def delete_dashboard_filter(filter_or_id, opts \\ [])

  def delete_dashboard_filter(%DashboardFilter{} = filter, opts),
    do: Mutation.run(filter, :delete, :dashboard_filter, opts)

  def delete_dashboard_filter(id, opts) do
    case Lotus.repo().get(DashboardFilter, id) do
      nil -> {:error, :not_found}
      filter -> delete_dashboard_filter(filter, opts)
    end
  end

  # ── Filter Mapping CRUD ────────────────────────────────────────────────────

  @doc """
  Lists all filter mappings for a card.
  """
  @spec list_card_filter_mappings(DashboardCard.t() | id()) :: [DashboardCardFilterMapping.t()]
  def list_card_filter_mappings(%DashboardCard{id: id}), do: list_card_filter_mappings(id)

  def list_card_filter_mappings(card_id) do
    from(m in DashboardCardFilterMapping,
      where: m.card_id == ^card_id,
      preload: [:filter]
    )
    |> Lotus.repo().all()
  end

  @doc """
  Creates a filter mapping connecting a dashboard filter to a card's query variable.

  ## Options

    * `:transform` - Optional transformation config for the filter value
    * `:context` - Opaque caller data passed to the content change middleware

  ## Examples

      iex> create_filter_mapping(card, filter, "start_date")
      {:ok, %DashboardCardFilterMapping{}}

      iex> create_filter_mapping(card, filter, "end_date", transform: %{type: "date_range_end"})
      {:ok, %DashboardCardFilterMapping{}}

  """
  @spec create_filter_mapping(
          DashboardCard.t() | id(),
          DashboardFilter.t() | id(),
          String.t(),
          keyword()
        ) ::
          {:ok, DashboardCardFilterMapping.t()}
          | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def create_filter_mapping(card, filter, variable_name, opts \\ [])

  def create_filter_mapping(%DashboardCard{id: card_id}, filter, variable_name, opts) do
    create_filter_mapping(card_id, filter, variable_name, opts)
  end

  def create_filter_mapping(card_id, %DashboardFilter{id: filter_id}, variable_name, opts) do
    create_filter_mapping(card_id, filter_id, variable_name, opts)
  end

  def create_filter_mapping(card_id, filter_id, variable_name, opts) do
    attrs = %{
      card_id: card_id,
      filter_id: filter_id,
      variable_name: variable_name,
      transform: Keyword.get(opts, :transform)
    }

    attrs
    |> DashboardCardFilterMapping.new()
    |> Mutation.run(:create, :filter_mapping, opts)
  end

  @doc """
  Deletes a filter mapping.
  """
  @spec delete_filter_mapping(DashboardCardFilterMapping.t() | id(), keyword()) ::
          {:ok, DashboardCardFilterMapping.t()}
          | {:error, Ecto.Changeset.t() | :not_found | Middleware.halted()}
  def delete_filter_mapping(mapping_or_id, opts \\ [])

  def delete_filter_mapping(%DashboardCardFilterMapping{} = mapping, opts),
    do: Mutation.run(mapping, :delete, :filter_mapping, opts)

  def delete_filter_mapping(id, opts) do
    case Lotus.repo().get(DashboardCardFilterMapping, id) do
      nil -> {:error, :not_found}
      mapping -> delete_filter_mapping(mapping, opts)
    end
  end

  # ── Execution ──────────────────────────────────────────────────────────────

  @doc """
  Runs all query cards in a dashboard and returns their results.

  Returns a map of card IDs to their results. By default, cards are executed
  in parallel for better performance.

  ## Options

    * `:filter_values` - Map of filter names to their current values
    * `:parallel` - Whether to run cards in parallel (default: true)
    * `:timeout` - Timeout per card in milliseconds (default: 30000)

  ## Filter Resolution

  Filter values are resolved to query variables through the configured mappings.
  For each card:
  1. Get all filter mappings for the card
  2. For each mapping, get the filter value from `:filter_values`
  3. Apply any configured transform to the value
  4. Pass the value to the query as the mapped variable name

  ## Examples

      iex> run_dashboard(dashboard, filter_values: %{"date_range" => "2024-01-01"})
      %{
        1 => {:ok, %Lotus.Result{}},
        2 => {:ok, %Lotus.Result{}},
        3 => {:error, "Missing required variable: status"}
      }

  """
  @spec run_dashboard(Dashboard.t() | id(), keyword()) :: %{
          id() => {:ok, Lotus.Result.t()} | {:error, term()}
        }
  def run_dashboard(dashboard, opts \\ [])

  def run_dashboard(%Dashboard{id: id}, opts), do: run_dashboard(id, opts)

  def run_dashboard(dashboard_id, opts) do
    cards = list_dashboard_cards(dashboard_id)
    filters = list_dashboard_filters(dashboard_id)
    filter_values = Keyword.get(opts, :filter_values, %{})
    parallel? = Keyword.get(opts, :parallel, true)
    timeout = Keyword.get(opts, :timeout, 30_000)

    filter_lookup = Map.new(filters, &{&1.id, &1})
    query_cards = Enum.filter(cards, &(&1.card_type == :query))

    # Preload all filter mappings for all query cards to avoid N+1 queries
    card_ids = Enum.map(query_cards, & &1.id)
    all_mappings = preload_mappings_for_cards(card_ids)

    if parallel? do
      run_cards_parallel(query_cards, filter_values, filter_lookup, all_mappings, opts, timeout)
    else
      run_cards_sequential(query_cards, filter_values, filter_lookup, all_mappings, opts)
    end
  end

  @doc """
  Runs a single dashboard card and returns its result.

  ## Options

    * `:filter_values` - Map of filter names to their current values
    * `:timeout` - Query timeout in milliseconds

  ## Examples

      iex> run_dashboard_card(card, filter_values: %{"user_id" => "123"})
      {:ok, %Lotus.Result{}}

  """
  @spec run_dashboard_card(DashboardCard.t() | id(), keyword()) ::
          {:ok, Lotus.Result.t()} | {:error, term()}
  def run_dashboard_card(card, opts \\ [])

  def run_dashboard_card(%DashboardCard{} = card, opts) do
    if card.card_type != :query do
      {:error, :not_a_query_card}
    else
      filter_values = Keyword.get(opts, :filter_values, %{})

      mappings = list_card_filter_mappings(card.id)
      filter_lookup = Map.new(mappings, fn m -> {m.filter_id, m.filter} end)
      vars = resolve_card_variables(mappings, filter_values, filter_lookup)

      query_opts = Keyword.drop(opts, [:filter_values])
      run_opts = Keyword.put(query_opts, :vars, vars)

      Lotus.run_query(card.query_id, run_opts)
    end
  end

  def run_dashboard_card(id, opts) do
    case get_dashboard_card(id) do
      nil -> {:error, :not_found}
      card -> run_dashboard_card(card, opts)
    end
  end

  defp preload_mappings_for_cards([]), do: %{}

  defp preload_mappings_for_cards(card_ids) do
    from(m in DashboardCardFilterMapping,
      where: m.card_id in ^card_ids,
      preload: [:filter]
    )
    |> Lotus.repo().all()
    |> Enum.group_by(& &1.card_id)
  end

  defp run_cards_parallel(cards, filter_values, filter_lookup, all_mappings, opts, timeout) do
    cards
    |> Enum.map(fn card ->
      # Capture card_id before spawning to handle timeouts
      card_id = card.id

      task =
        Task.Supervisor.async(Lotus.Supervisor.task_supervisor_name(Lotus), fn ->
          execute_card(card, filter_values, filter_lookup, all_mappings, opts)
        end)

      {card_id, task}
    end)
    |> Enum.reduce(%{}, fn {card_id, task}, acc ->
      result =
        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, result} -> result
          nil -> {:error, :timeout}
        end

      Map.put(acc, card_id, result)
    end)
  end

  defp run_cards_sequential(cards, filter_values, filter_lookup, all_mappings, opts) do
    Enum.reduce(cards, %{}, fn card, acc ->
      result = execute_card(card, filter_values, filter_lookup, all_mappings, opts)
      Map.put(acc, card.id, result)
    end)
  end

  defp execute_card(card, filter_values, filter_lookup, all_mappings, opts) do
    mappings = Map.get(all_mappings, card.id, [])
    vars = resolve_card_variables(mappings, filter_values, filter_lookup)

    query_opts = Keyword.drop(opts, [:filter_values, :parallel, :timeout])
    run_opts = Keyword.put(query_opts, :vars, vars)

    Lotus.run_query(card.query_id, run_opts)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp resolve_card_variables(mappings, filter_values, filter_lookup) do
    Enum.reduce(mappings, %{}, fn mapping, vars ->
      filter = Map.get(filter_lookup, mapping.filter_id)

      if filter do
        # Get filter value from supplied values or fall back to default
        raw_value = Map.get(filter_values, filter.name) || filter.default_value

        if raw_value do
          # Apply transform if configured
          value = apply_transform(raw_value, mapping.transform)
          Map.put(vars, mapping.variable_name, value)
        else
          vars
        end
      else
        vars
      end
    end)
  end

  defp apply_transform(value, nil), do: value

  defp apply_transform(value, %{"type" => "date_range_start"}) when is_binary(value) do
    # Assumes value is in format "start_date,end_date" or just a date
    value |> String.split(",") |> List.first()
  end

  defp apply_transform(value, %{"type" => "date_range_end"}) when is_binary(value) do
    # Assumes value is in format "start_date,end_date" or just a date
    case String.split(value, ",") do
      [_start, end_date] -> end_date
      [single] -> single
    end
  end

  defp apply_transform(value, _transform), do: value
end
