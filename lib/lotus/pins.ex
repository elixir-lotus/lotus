defmodule Lotus.Pins do
  @moduledoc """
  Pins: a result a person keeps beside their next runs of a query, to
  compare them, kept across visits.

      {:ok, pin} =
        Lotus.Pins.pin(result,
          %{query_id: query.id, statement: "SELECT …", data_source: "main"},
          owner_id: "42")

      Lotus.Pins.get_pin(query.id, owner_id: "42")
      Lotus.Pins.unpin(query.id, owner_id: "42")

  A person has one pin per query: pinning again replaces it. `query_id` is
  `nil` for a query not saved yet (the editor's new query). The pin keeps
  the rows the result had (a page, up to `#{1_000}`), as text: what was
  shown, not the query to run again. Deleting a query deletes its pins.

  `:owner_id` and `:tenant_id` say whose pin it is; the host gives them
  (Lotus never sets them). A call without them reads and writes the pins
  that have none.
  """

  import Ecto.Query, only: [where: 3]

  alias Lotus.Result
  alias Lotus.Storage.Pin
  alias Lotus.Value

  @max_rows 1_000

  @doc """
  Pins `result` for the query of `attrs` (`:query_id`, `:statement`,
  `:text`, `:data_source`, `:search_path`, `:vars`), replacing the
  person's pin of that query.
  """
  @spec pin(Result.t() | map(), map(), keyword()) :: {:ok, Pin.t()} | {:error, Ecto.Changeset.t()}
  def pin(result, attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("result", snapshot(result))
      |> Map.put_new("pinned_at", DateTime.utc_now())
      |> Map.update("vars", %{}, &stringify_vars/1)

    Lotus.repo().transaction(fn ->
      attrs["query_id"] |> scope(opts) |> Lotus.repo().delete_all()

      %Pin{owner_id: id(opts[:owner_id]), tenant_id: id(opts[:tenant_id])}
      |> Pin.changeset(attrs)
      |> Lotus.repo().insert()
      |> case do
        {:ok, pin} -> pin
        {:error, changeset} -> Lotus.repo().rollback(changeset)
      end
    end)
  end

  @doc "The person's pin of a query (`nil`: the new query), or `nil`."
  @spec get_pin(term() | nil, keyword()) :: Pin.t() | nil
  def get_pin(query_id, opts \\ []),
    do: query_id |> scope(opts) |> Ecto.Query.first(:id) |> Lotus.repo().one()

  @doc "Removes the person's pin of a query (`nil`: the new query)."
  @spec unpin(term() | nil, keyword()) :: :ok
  def unpin(query_id, opts \\ []) do
    query_id |> scope(opts) |> Lotus.repo().delete_all()
    :ok
  end

  @doc """
  What a pin keeps of a result: its columns, its first `#{@max_rows}` rows
  as they show (`Lotus.Value.to_display_string/1`, `nil` kept), its row
  count, the total the source counted and the time it took.
  """
  @spec snapshot(Result.t() | map()) :: map()
  def snapshot(result) do
    rows = result |> Map.get(:rows) |> List.wrap() |> Enum.take(@max_rows)

    %{
      "columns" => Map.get(result, :columns) || [],
      "rows" => Enum.map(rows, fn row -> Enum.map(row, &cell/1) end),
      "num_rows" => Map.get(result, :num_rows) || length(rows),
      "total_count" => get_in(result, [Access.key(:meta, %{}), :total_count]),
      "duration_ms" => Map.get(result, :duration_ms)
    }
  end

  defp cell(nil), do: nil
  defp cell(value), do: Value.to_display_string(value)

  defp stringify_vars(nil), do: %{}

  defp stringify_vars(vars) when is_map(vars),
    do: Map.new(vars, fn {k, v} -> {to_string(k), v} end)

  defp scope(query_id, opts) do
    Pin
    |> by(:query_id, query_id)
    |> by(:owner_id, id(opts[:owner_id]))
    |> by(:tenant_id, id(opts[:tenant_id]))
  end

  defp by(query, field, nil), do: where(query, [p], is_nil(field(p, ^field)))
  defp by(query, field, value), do: where(query, [p], field(p, ^field) == ^value)

  defp id(nil), do: nil
  defp id(""), do: nil
  defp id(id) when is_integer(id), do: Integer.to_string(id)
  defp id(id) when is_binary(id), do: id
end
