defmodule Lotus.Storage.Mutation do
  @moduledoc false

  require Logger

  alias Ecto.Changeset
  alias Lotus.{Middleware, Telemetry}

  @ops [:create, :update, :delete, :enable_sharing, :disable_sharing]
  @resources [
    :query,
    :visualization,
    :dashboard,
    :dashboard_card,
    :dashboard_filter,
    :filter_mapping
  ]

  @type op :: :create | :update | :delete | :enable_sharing | :disable_sharing
  @type resource ::
          :query
          | :visualization
          | :dashboard
          | :dashboard_card
          | :dashboard_filter
          | :filter_mapping
  @type change :: {Changeset.t() | struct(), op(), resource()}

  @spec run(Changeset.t() | struct(), op(), resource(), keyword()) ::
          {:ok, struct()} | {:error, Changeset.t() | Middleware.halted() | term()}
  def run(changeset_or_record, op, resource, opts) do
    case run_all([{changeset_or_record, op, resource}], opts) do
      {:ok, [record]} -> {:ok, record}
      {:error, _reason} = error -> error
    end
  end

  @spec run_all([change()], keyword()) ::
          {:ok, [struct()]} | {:error, Changeset.t() | Middleware.halted() | term()}
  def run_all([], _opts), do: {:ok, []}

  def run_all(changes, opts) when is_list(changes) do
    context = Keyword.get(opts, :context)
    pending = Enum.map(changes, &start(&1, context))

    result =
      try do
        with :ok <- run_before_events(pending) do
          write_all(pending)
        end
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          fail_all(pending, %{kind: kind, reason: reason, stacktrace: stacktrace})
          :erlang.raise(kind, reason, stacktrace)
      end

    case result do
      {:ok, records} ->
        Enum.zip_with(pending, records, &finish/2)
        {:ok, records}

      {:error, reason} = error ->
        fail_all(pending, %{kind: :error, reason: reason})
        error
    end
  end

  defp start({%Changeset{} = changeset, op, resource}, context)
       when op in @ops and resource in @resources do
    metadata = %{
      op: op,
      resource: resource,
      record: stored_record(op, changeset),
      context: context
    }

    %{
      changeset: changeset,
      metadata: metadata,
      start_time: Telemetry.content_change_start(metadata)
    }
  end

  defp start({record, :delete, resource}, context) when is_struct(record) do
    start({Changeset.change(record), :delete, resource}, context)
  end

  defp stored_record(:create, _changeset), do: nil
  defp stored_record(_op, %Changeset{data: record}), do: record

  defp run_before_events(pending) do
    Enum.reduce_while(pending, :ok, fn change, :ok ->
      payload = Map.put(change.metadata, :changeset, change.changeset)

      case Middleware.run(:before_content_change, payload) do
        {:cont, _payload} -> {:cont, :ok}
        {:halt, reason} -> {:halt, {:error, {:halted, reason}}}
      end
    end)
  end

  defp write_all([change]) do
    with {:ok, record} <- write(change), do: {:ok, [record]}
  end

  defp write_all(pending) do
    repo = Lotus.repo()

    repo.transaction(fn ->
      Enum.map(pending, fn change ->
        case write(change) do
          {:ok, record} -> record
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end)
  end

  defp write(%{changeset: changeset, metadata: %{op: :create}}),
    do: Lotus.repo().insert(changeset)

  defp write(%{changeset: changeset, metadata: %{op: :delete}}),
    do: Lotus.repo().delete(changeset)

  defp write(%{changeset: changeset}), do: Lotus.repo().update(changeset)

  defp finish(%{changeset: changeset, metadata: metadata} = change, record) do
    written =
      Map.merge(metadata, %{record: record, changes: written_changes(changeset, record)})

    if wrote?(metadata.op, changeset), do: after_content_change(written)

    Telemetry.content_change_stop(change.start_time, written)
  end

  defp fail_all(pending, failure) do
    Enum.each(pending, fn change ->
      Telemetry.content_change_exception(change.start_time, Map.merge(change.metadata, failure))
    end)
  end

  defp written_changes(%Changeset{changes: changes}, record) do
    Map.new(changes, fn {field, _change} -> {field, Map.fetch!(record, field)} end)
  end

  defp wrote?(op, _changeset) when op in [:create, :delete], do: true
  defp wrote?(_op, %Changeset{changes: changes}), do: changes != %{}

  defp after_content_change(%{op: op, resource: resource} = payload) do
    case Middleware.run(:after_content_change, payload) do
      {:cont, _payload} ->
        :ok

      {:halt, exception} when is_exception(exception) ->
        Logger.error(
          "An :after_content_change plug raised after the #{resource} #{op} was written. " <>
            "The write stands; later plugs on the event did not run.\n" <>
            Exception.format(:error, exception)
        )

      {:halt, reason} ->
        Logger.warning(
          "An :after_content_change plug halted with #{inspect(reason)} after the " <>
            "#{resource} #{op} was written. The write stands; later plugs on the event did not run."
        )
    end
  catch
    kind, reason ->
      Logger.error(
        "An :after_content_change plug failed after the #{resource} #{op} was written. " <>
          "The write stands; later plugs on the event did not run.\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end
end
