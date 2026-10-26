defmodule Lotus.Source.Adapter.Cancel do
  @moduledoc """
  Capability behaviour for sources that can stop a statement while it runs,
  from another process.

  A UI that runs a statement for a person offers a button to stop it.
  `Lotus.run_statement/3` and `Lotus.run_query/2` take
  `on_cancel_token: fun`, and `Lotus.cancel/1` stops the statement with the
  token `fun` received. `Lotus.cancellable?/1` says whether a source can.

  Two callbacks make it. `c:cancel_handle/1` runs inside the statement's
  transaction, just before the statement, and returns what names it in the
  database: a backend pid, a connection id, a job id. `c:cancel/2` runs in
  another process, with that handle, and asks the database to stop it.

  `Lotus.Source.Adapters.Postgres` declares it with `pg_backend_pid()` and
  `pg_cancel_backend/1`, and `Lotus.Source.Adapters.MySQL` with
  `CONNECTION_ID()` and `KILL QUERY`. SQLite runs in the calling process and
  does not.

  Declare it next to the core behaviour:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Cancel

  `Lotus.Source.Adapter` dispatches to it only when the module declares this
  behaviour.
  """

  @doc """
  Return the handle of the statement about to run.

  Lotus calls it inside the statement's transaction
  (`c:Lotus.Source.Adapter.transaction/3`), on the connection the statement
  will run on, just before `c:Lotus.Source.Adapter.execute_query/4`. The
  handle is any term `c:cancel/2` takes. Return `{:error, reason}` when the
  source cannot name the statement: it is not run.
  """
  @callback cancel_handle(state :: term()) :: {:ok, handle :: term()} | {:error, term()}

  @doc """
  Stop the statement `handle` names.

  Lotus calls it from another process than the one running the statement,
  so it must not use that statement's connection: take another one from the
  pool, or call the engine's API. Lotus calls it only while the statement's
  transaction is open, so the handle never names another caller's
  statement. The statement then returns, with an error or not; Lotus
  reports it as cancelled either way.
  """
  @callback cancel(state :: term(), handle :: term()) :: :ok | {:error, term()}
end
