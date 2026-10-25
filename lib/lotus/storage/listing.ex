defmodule Lotus.Storage.Listing do
  @moduledoc false
  # A list or a get of content for a caller: when the caller passes
  # `:context`, the `:list_content` middleware narrows the query to what that
  # caller may read. Without `:context`, the query is as it is: Lotus's own
  # lookups (the scheduler, a saved query run by id) see everything.

  import Ecto.Query, only: [where: 2]

  alias Lotus.Middleware

  @doc """
  The query, narrowed by the `:list_content` plugs when `opts` has a
  `:context`. A halt narrows it to nothing. A plug that continues with
  something other than an `Ecto.Query` leaves the query as it was.
  """
  @spec narrow(Ecto.Queryable.t(), :query | :dashboard, keyword()) :: Ecto.Query.t()
  def narrow(queryable, resource, opts) do
    query = Ecto.Queryable.to_query(queryable)

    if Keyword.has_key?(opts, :context) do
      payload = %{
        resource: resource,
        query: query,
        context: opts[:context],
        scope: opts[:scope],
        filter: opts[:filter]
      }

      case Middleware.run(:list_content, payload) do
        {:cont, %{query: %Ecto.Query{} = narrowed}} -> narrowed
        {:cont, _payload} -> query
        {:halt, _reason} -> where(query, false)
      end
    else
      query
    end
  end
end
