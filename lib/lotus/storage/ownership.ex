defmodule Lotus.Storage.Ownership do
  @moduledoc false

  # The `owner_id` and `tenant_id` of queries and dashboards: set from the
  # options of a create or update, never cast from its attributes, and
  # filtered on in lists.

  import Ecto.Query, only: [where: 3]

  alias Ecto.Changeset

  @fields [:owner_id, :tenant_id]

  @doc """
  Puts the `:owner_id` and `:tenant_id` of `opts` on the changeset. A key not
  in `opts` leaves the field as it is; `nil` or `""` clears it.
  """
  @spec put(Changeset.t(), keyword()) :: Changeset.t()
  def put(%Changeset{} = changeset, opts) do
    Enum.reduce(@fields, changeset, fn field, changeset ->
      case Keyword.fetch(opts, field) do
        {:ok, value} -> put_field(changeset, field, value)
        :error -> changeset
      end
    end)
  end

  defp put_field(changeset, field, value) when value in [nil, ""],
    do: Changeset.put_change(changeset, field, nil)

  defp put_field(changeset, field, value) when is_binary(value),
    do: Changeset.put_change(changeset, field, value)

  defp put_field(changeset, field, value) when is_integer(value),
    do: Changeset.put_change(changeset, field, Integer.to_string(value))

  defp put_field(changeset, field, _value),
    do: Changeset.add_error(changeset, field, "must be a string, an integer or nil")

  @doc """
  Filters `query` by the `:owner_id` and `:tenant_id` of `opts`: an id, `nil`
  for the rows without one, or a list of either. A key not in `opts` does not
  filter.
  """
  @spec filter(Ecto.Queryable.t(), keyword()) :: Ecto.Query.t()
  def filter(query, opts) do
    Enum.reduce(@fields, Ecto.Queryable.to_query(query), fn field, query ->
      case Keyword.fetch(opts, field) do
        {:ok, values} when is_list(values) -> filter_field(query, field, values)
        {:ok, value} -> filter_field(query, field, [value])
        :error -> query
      end
    end)
  end

  defp filter_field(query, field, values) do
    {nils, ids} = Enum.split_with(values, &(&1 in [nil, ""]))
    ids = Enum.map(ids, &to_id/1)

    case {nils, ids} do
      {[], ids} -> where(query, [r], field(r, ^field) in ^ids)
      {_nils, []} -> where(query, [r], is_nil(field(r, ^field)))
      {_nils, ids} -> where(query, [r], field(r, ^field) in ^ids or is_nil(field(r, ^field)))
    end
  end

  defp to_id(id) when is_binary(id), do: id
  defp to_id(id) when is_integer(id), do: Integer.to_string(id)

  defp to_id(id) do
    raise ArgumentError,
          "an :owner_id or :tenant_id filter takes strings, integers or nil, got: #{inspect(id)}"
  end
end
