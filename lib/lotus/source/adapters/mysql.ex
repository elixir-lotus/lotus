defmodule Lotus.Source.Adapters.MySQL do
  @moduledoc """
  MySQL data source, built on `Lotus.Source.Adapters.Ecto`.

  Resolved automatically for any repo whose Ecto adapter is
  `Ecto.Adapters.MyXQL`, so hosts normally never name this module —
  they configure the repo and Lotus wraps it.

  Dialect behaviour comes from
  `Lotus.Source.Adapters.Ecto.Dialects.MySQL`: databases-as-schemas, `EXPLAIN FORMAT=JSON` query plans, and `max_execution_time` as the statement timeout.

  It also declares `Lotus.Source.Adapter.Streaming` and
  `Lotus.Source.Adapter.Cancel`.
  """

  alias Lotus.Runner.Cancel
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  use Lotus.Source.Adapters.Ecto,
    dialect: Lotus.Source.Adapters.Ecto.Dialects.MySQL,
    connection: [
      kind: "mysql",
      label: "MySQL",
      fields: EctoAdapter.server_fields(3306)
    ]

  @behaviour Lotus.Source.Adapter.Streaming

  @impl Lotus.Source.Adapter.Streaming
  defdelegate stream_query(state, sql, params, opts),
    to: Lotus.Source.Adapters.Ecto,
    as: :do_stream_query

  @behaviour Lotus.Source.Adapter.Cancel

  @doc """
  The id of the connection the statement runs on, from `CONNECTION_ID()`,
  read inside the statement's transaction.
  """
  @impl Lotus.Source.Adapter.Cancel
  def cancel_handle(state) do
    EctoAdapter.with_repo(state, fn repo ->
      case repo.query("SELECT CONNECTION_ID()") do
        {:ok, %{rows: [[id]]}} when is_integer(id) -> {:ok, id}
        {:ok, _other} -> {:error, "Could not read the connection id"}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Stops the statement running on a connection with `KILL QUERY`, on another
  connection of the pool. The connection stays open.
  """
  @impl Lotus.Source.Adapter.Cancel
  def cancel(state, id) when is_integer(id) and id > 0 do
    EctoAdapter.with_repo(state, fn repo ->
      # KILL takes no placeholder; the id is an integer.
      case repo.query("KILL QUERY #{id}", [], timeout: Cancel.cancel_timeout()) do
        {:ok, _result} -> :ok
        {:error, error} -> {:error, Exception.message(error)}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
