defmodule Lotus.Source.Adapters.Postgres do
  @moduledoc """
  PostgreSQL data source, built on `Lotus.Source.Adapters.Ecto`.

  Resolved automatically for any repo whose Ecto adapter is
  `Ecto.Adapters.Postgres`, so hosts normally never name this module —
  they configure the repo and Lotus wraps it.

  Dialect behaviour comes from
  `Lotus.Source.Adapters.Ecto.Dialects.Postgres`: schemas, `EXPLAIN (FORMAT JSON)` query plans, a session `search_path`, and `statement_timeout`.

  It also declares `Lotus.Source.Adapter.Session`, `Lotus.Source.Adapter.Streaming`
  and `Lotus.Source.Adapter.Cancel`.
  """

  alias Lotus.Runner.Cancel
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  use Lotus.Source.Adapters.Ecto,
    dialect: Lotus.Source.Adapters.Ecto.Dialects.Postgres,
    connection: [
      kind: "postgres",
      label: "PostgreSQL",
      fields: EctoAdapter.server_fields(5432)
    ]

  @behaviour Lotus.Source.Adapter.Streaming

  @impl Lotus.Source.Adapter.Streaming
  defdelegate stream_query(state, sql, params, opts),
    to: Lotus.Source.Adapters.Ecto,
    as: :do_stream_query

  @behaviour Lotus.Source.Adapter.Session

  # A custom setting (`prefix.name`), so a statement's session cannot touch
  # the settings Lotus relies on, such as `transaction_read_only`,
  # `statement_timeout`, `search_path` or `role`.
  @custom_setting ~r/\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+\z/

  @doc """
  Applies each setting with `set_config(name, value, true)`, local to the
  statement's transaction, so a policy reads it with
  `current_setting('app.tenant_id', true)`.

  Only custom settings, named `prefix.name`, are taken: a built-in one such
  as `role` or `transaction_read_only` is refused, and the statement does not
  run.
  """
  @impl Lotus.Source.Adapter.Session
  def setup_session(state, settings, _opts) do
    case Enum.reject(Map.keys(settings), &Regex.match?(@custom_setting, &1)) do
      [] ->
        EctoAdapter.with_repo(state, fn repo ->
          Enum.each(settings, fn {name, value} ->
            repo.query!("SELECT set_config($1, $2, true)", [name, value])
          end)
        end)

        :ok

      refused ->
        {:error,
         "Session settings must be custom settings named prefix.name, got: " <>
           Enum.map_join(refused, ", ", &inspect/1)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @behaviour Lotus.Source.Adapter.Cancel

  @doc """
  The pid of the backend the statement runs on, from `pg_backend_pid()`,
  read inside the statement's transaction.
  """
  @impl Lotus.Source.Adapter.Cancel
  def cancel_handle(state) do
    EctoAdapter.with_repo(state, fn repo ->
      case repo.query("SELECT pg_backend_pid()") do
        {:ok, %{rows: [[pid]]}} when is_integer(pid) -> {:ok, pid}
        {:ok, _other} -> {:error, "Could not read the backend pid"}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Stops the statement running on a backend with `pg_cancel_backend/1`, on
  another connection of the pool.
  """
  @impl Lotus.Source.Adapter.Cancel
  def cancel(state, pid) when is_integer(pid) do
    EctoAdapter.with_repo(state, fn repo ->
      case repo.query("SELECT pg_cancel_backend($1)", [pid], timeout: Cancel.cancel_timeout()) do
        {:ok, %{rows: [[true]]}} -> :ok
        {:ok, _other} -> {:error, "The database did not cancel the query"}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
