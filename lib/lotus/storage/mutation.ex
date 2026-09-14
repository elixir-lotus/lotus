defmodule Lotus.Storage.Mutation do
  @moduledoc false
  # Every content write in `Lotus.Storage`, `Lotus.Dashboards` and `Lotus.Viz`
  # goes through `run/4`, so the event order, the halt shape and the point
  # after the write are defined once. The contract is documented in
  # `Lotus.Middleware`.

  alias Ecto.Changeset
  alias Lotus.{Middleware, Telemetry}

  @ops [:create, :update, :delete]
  @resources [
    :query,
    :visualization,
    :dashboard,
    :dashboard_card,
    :dashboard_filter,
    :filter_mapping
  ]

  @type op :: :create | :update | :delete
  @type resource ::
          :query
          | :visualization
          | :dashboard
          | :dashboard_card
          | :dashboard_filter
          | :filter_mapping

  @spec run(Changeset.t(), op(), resource(), keyword()) ::
          {:ok, struct()} | {:error, Changeset.t() | Middleware.halted()}
  def run(%Changeset{} = changeset, op, resource, opts)
      when op in @ops and resource in @resources do
    context = Keyword.get(opts, :context)

    before_payload = %{
      op: op,
      resource: resource,
      record: stored_record(op, changeset),
      changeset: changeset,
      context: context
    }

    with {:cont, _payload} <- Middleware.run(:before_content_change, before_payload),
         {:ok, record} <- write(op, changeset) do
      after_content_change(%{
        op: op,
        resource: resource,
        record: record,
        changes: changeset.changes,
        context: context
      })

      {:ok, record}
    else
      {:halt, reason} -> {:error, {:halted, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp stored_record(:create, _changeset), do: nil
  defp stored_record(_op, %Changeset{data: record}), do: record

  defp write(:create, changeset), do: Lotus.repo().insert(changeset)
  defp write(:update, changeset), do: Lotus.repo().update(changeset)
  defp write(:delete, changeset), do: Lotus.repo().delete(changeset)

  # The write has happened, so a halt here has nothing left to stop.
  defp after_content_change(payload) do
    _ = Middleware.run(:after_content_change, payload)
    Telemetry.content_change(payload)
  end
end
