defmodule Lotus.Source.Adapter.Session do
  @moduledoc """
  Capability behaviour for sources that apply settings to the connection for
  one statement: the `:session` of a `Lotus.Query.Statement`.

  Row-level security in the database is the use: a `:before_query` plug puts
  the actor's attributes in the statement's session, and a policy reads them,
  so every statement is filtered without being rewritten.

      # A :before_query plug
      def call(%{statement: statement, context: %{tenant_id: id}} = payload, _opts) do
        {:cont, %{payload | statement: %{statement | session: %{"app.tenant_id" => id}}}}
      end

      -- A PostgreSQL policy
      CREATE POLICY tenant_rows ON orders
        USING (tenant_id = current_setting('app.tenant_id', true));

  `Lotus.Source.Adapters.Postgres` declares it. A statement with a session on
  a source whose adapter does not is refused: running it would return the
  rows the policy was meant to hide.

  Declare it next to the core behaviour:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Session

  `Lotus.Source.Adapter` dispatches to it only when the module declares this
  behaviour.
  """

  @doc """
  Apply `settings` to the connection, for the statement about to run.

  Lotus calls it inside the statement's transaction (`c:Lotus.Source.Adapter.transaction/3`),
  just before `c:Lotus.Source.Adapter.execute_query/4`, with names and values
  as strings. The settings must end with the transaction, so the next
  statement on the connection does not see them. Return `{:error, reason}` to
  refuse a setting the source cannot apply: the statement is not run.
  """
  @callback setup_session(
              state :: term(),
              settings :: %{optional(String.t()) => String.t()},
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
