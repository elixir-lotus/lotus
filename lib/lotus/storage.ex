defmodule Lotus.Storage do
  @moduledoc """
  Storage operations for Lotus queries.

  Handles CRUD operations for persisting and retrieving queries.

  ## Content changes

  `create_query/2`, `update_query/3` and `delete_query/2` take `opts` with a
  `:context`, opaque caller data such as the current user. Each write fires the
  `:before_content_change` and `:after_content_change` middleware. A plug that
  halts makes the function return `{:error, {:halted, reason}}` and nothing is
  written.

  ## Owner and tenant

  A query has an `owner_id` and a `tenant_id`: ids the host supplies, as
  strings, `nil` when it has none. Lotus stores them and filters lists by
  them; it does not decide them. They are not attributes, so a host that
  passes form params as `attrs` does not let a user set them: they are given
  as the `:owner_id` and `:tenant_id` options of `create_query/2` and
  `update_query/3`, or put on the changeset by a `:before_content_change`
  plug. A name is unique within a tenant. `list_queries_by/1` filters by both.

  Nothing in Lotus reads them to allow or refuse access: `get_query/1` finds a
  query of any tenant. A host or package that isolates tenants checks the
  record it gets.

  Deleting a query also deletes its visualizations, sets `query_id` to `nil`
  on the dashboard cards that showed it and sets `source_query_id` to `nil` on
  the dashboard filters that got their options from it. Those changes fire no event; the
  query's `:delete` is the event to gate and to record. See `Lotus.Middleware`.
  """

  import Ecto.Query
  import Lotus.Helpers, only: [escape_like: 1]

  alias Lotus.{Middleware, Result}
  alias Lotus.Storage.{Listing, Mutation, Ownership, Query}

  @type id :: integer() | binary()
  @type attrs :: map()
  @type query_list :: [Query.t()]
  @type changeset_error :: Ecto.Changeset.t()

  @doc """
  Lists all queries from the database.

  Returns a list of Query structs.

  ## Options

    * `:context` - The caller, for the `:list_content` middleware, which
      narrows the list to what they may read. Without it, every query is
      listed.
  """
  @spec list_queries(keyword()) :: query_list()
  def list_queries(opts \\ []) do
    Query |> Listing.narrow(:query, opts) |> Lotus.repo().all()
  end

  @doc """
  Lists queries with filtering search term.

  ## Options

    * `:search` - Search term to match against query names (case insensitive)
    * `:owner_id` - Only the queries of this owner: an id, `nil` for the
      queries without one, or a list of either
    * `:tenant_id` - Only the queries of this tenant, as `:owner_id`.
      `tenant_id: ["acme", nil]` lists the tenant's queries and those of no
      tenant
    * `:context` - The caller, for the `:list_content` middleware, which
      narrows the list to what they may read. Without it, every query is
      listed.

  ## Examples

      iex> list_queries_by(search: "user")
      [%Query{}, ...]

      iex> list_queries_by(tenant_id: "acme", owner_id: "42")
      [%Query{tenant_id: "acme", owner_id: "42"}, ...]

  """
  @spec list_queries_by(keyword()) :: [Query.t()]
  def list_queries_by(opts \\ []) do
    q = Query |> Ownership.filter(opts) |> Listing.narrow(:query, opts)

    q =
      case Keyword.get(opts, :search) do
        nil ->
          q

        term ->
          escaped = escape_like(term)
          from(query in q, where: ilike(query.name, ^"%#{escaped}%"))
      end

    Lotus.repo().all(q)
  end

  @doc """
  Gets a single query by ID.

  Returns `nil` if the Query does not exist, or, with `context:`, if the
  `:list_content` middleware does not let that caller read it.
  """
  @spec get_query(id(), keyword()) :: Query.t() | nil
  def get_query(id, opts \\ []) do
    Query |> Listing.narrow(:query, opts) |> Lotus.repo().get(id)
  end

  @doc """
  Gets a single query by ID, as `get_query/2`.

  Raises `Ecto.NoResultsError` if the Query does not exist, or the caller may
  not read it.
  """
  @spec get_query!(id(), keyword()) :: Query.t() | no_return()
  def get_query!(id, opts \\ []) do
    Query |> Listing.narrow(:query, opts) |> Lotus.repo().get!(id)
  end

  @doc """
  Creates a new query.

  ## Options

    * `:context` - Caller data for the content change middleware
    * `:owner_id`, `:tenant_id` - The query's owner and tenant (see
      "Owner and tenant" above)

  ## Examples

      iex> create_query(%{name: "Users", statement: "SELECT * FROM users"})
      {:ok, %Query{}}

      iex> create_query(%{})
      {:error, %Ecto.Changeset{}}
  """
  @spec create_query(attrs(), keyword()) ::
          {:ok, Query.t()} | {:error, changeset_error() | Middleware.halted()}
  def create_query(attrs, opts \\ []) do
    attrs
    |> Query.new()
    |> Ownership.put(opts)
    |> Mutation.run(:create, :query, opts)
  end

  @doc """
  Updates a query.

  Takes the options of `create_query/2`. An `:owner_id` or `:tenant_id` that
  is not given stays as it is; `nil` clears it.

  ## Examples

      iex> update_query(query, %{name: "New Name"})
      {:ok, %Query{}}

      iex> update_query(query, %{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  @spec update_query(Query.t(), attrs(), keyword()) ::
          {:ok, Query.t()} | {:error, changeset_error() | Middleware.halted()}
  def update_query(%Query{} = query, attrs, opts \\ []) do
    query
    |> Query.update(attrs)
    |> Ownership.put(opts)
    |> Mutation.run(:update, :query, opts)
  end

  @doc """
  Deletes a query.

  ## Examples

      iex> delete_query(query)
      {:ok, %Query{}}
  """
  @spec delete_query(Query.t(), keyword()) ::
          {:ok, Query.t()} | {:error, changeset_error() | Middleware.halted()}
  def delete_query(%Query{} = query, opts \\ []) do
    Mutation.run(query, :delete, :query, opts)
  end

  @doc """
  Run a saved query directly from Storage.

  This is a convenience function that delegates to `Lotus.run_query/2`.

  ## Examples

      query = get_query!(123)
      {:ok, result} = run(query, statement_timeout_ms: 3_000)

  """
  @spec run(Query.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Query{} = q, opts \\ []), do: Lotus.run_query(q, opts)
end
