defmodule Lotus.Storage do
  @moduledoc """
  Storage operations for Lotus queries.

  Handles CRUD operations for persisting and retrieving queries.

  ## Content changes

  `create_query/2`, `update_query/3` and `delete_query/2` take `opts` with a
  `:context`, opaque caller data such as the current user. Each write fires the
  `:before_content_change` and `:after_content_change` middleware. A plug that
  halts makes the function return `{:error, {:halted, reason}}` and nothing is
  written. See `Lotus.Middleware`.
  """

  import Ecto.Query
  import Lotus.Helpers, only: [escape_like: 1]

  alias Lotus.{Middleware, Result}
  alias Lotus.Storage.{Mutation, Query}

  @type id :: integer() | binary()
  @type attrs :: map()
  @type query_list :: [Query.t()]
  @type changeset_error :: Ecto.Changeset.t()

  @doc """
  Lists all queries from the database.

  Returns a list of Query structs.
  """
  @spec list_queries() :: query_list()
  def list_queries do
    Lotus.repo().all(Query)
  end

  @doc """
  Lists queries with filtering search term.

  ## Options

    * `:search` - Search term to match against query names (case insensitive)

  ## Examples

      iex> list_queries_by(search: "user")
      [%Query{}, ...]

  """
  @spec list_queries_by(keyword()) :: [Query.t()]
  def list_queries_by(opts \\ []) do
    q = from(Query)

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

  Returns `nil` if the Query does not exist.
  """
  @spec get_query(id()) :: Query.t() | nil
  def get_query(id) do
    Lotus.repo().get(Query, id)
  end

  @doc """
  Gets a single query by ID.

  Raises `Ecto.NoResultsError` if the Query does not exist.
  """
  @spec get_query!(id()) :: Query.t() | no_return()
  def get_query!(id) do
    Lotus.repo().get!(Query, id)
  end

  @doc """
  Creates a new query.

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
    |> Mutation.run(:create, :query, opts)
  end

  @doc """
  Updates a query.

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
    query
    |> Ecto.Changeset.change()
    |> Mutation.run(:delete, :query, opts)
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
