defmodule Lotus.Viz do
  @moduledoc """
  Service functions for managing query visualizations in Lotus storage.

  - CRUD wrappers around `Lotus.Storage.QueryVisualization`
  - Validation against a `%Lotus.Result{}` to ensure field references exist and
    numeric aggregations apply to numeric columns.

  ## Content changes

  `create_visualization/3`, `update_visualization/3` and
  `delete_visualization/2` take `opts` with a `:context`, opaque caller data
  such as the current user. Each write fires the `:before_content_change` and
  `:after_content_change` middleware with resource `:visualization`. A plug
  that halts makes the function return `{:error, {:halted, reason}}` and
  nothing is written. See `Lotus.Middleware`.
  """

  import Ecto.Query
  alias Lotus.{Middleware, Result}
  alias Lotus.Storage.{Mutation, Query}
  alias Lotus.Storage.QueryVisualization, as: Viz

  @type id :: integer() | binary()
  @type attrs :: map()

  @spec list_visualizations(Query.t() | id()) :: [Viz.t()]
  def list_visualizations(%Query{id: id}), do: list_visualizations(id)

  def list_visualizations(query_id) do
    from(v in Viz,
      where: v.query_id == ^query_id,
      order_by: [asc: v.position, asc: v.id]
    )
    |> Lotus.repo().all()
  end

  @spec create_visualization(Query.t() | id(), attrs(), keyword()) ::
          {:ok, Viz.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def create_visualization(query_or_id, attrs, opts \\ [])

  def create_visualization(%Query{id: id}, attrs, opts), do: create_visualization(id, attrs, opts)

  def create_visualization(query_id, attrs, opts) do
    attrs
    |> Map.put(:query_id, query_id)
    |> Viz.new()
    |> Mutation.run(:create, :visualization, opts)
  end

  @spec update_visualization(Viz.t(), attrs(), keyword()) ::
          {:ok, Viz.t()} | {:error, Ecto.Changeset.t() | Middleware.halted()}
  def update_visualization(%Viz{} = viz, attrs, opts \\ []) do
    viz
    |> Viz.update(attrs)
    |> Mutation.run(:update, :visualization, opts)
  end

  @spec delete_visualization(Viz.t() | id(), keyword()) ::
          {:ok, Viz.t()} | {:error, Ecto.Changeset.t() | :not_found | Middleware.halted()}
  def delete_visualization(viz_or_id, opts \\ [])

  def delete_visualization(%Viz{} = viz, opts) do
    viz
    |> Ecto.Changeset.change()
    |> Mutation.run(:delete, :visualization, opts)
  end

  def delete_visualization(id, opts) do
    case Lotus.repo().get(Viz, id) do
      nil -> {:error, :not_found}
      viz -> delete_visualization(viz, opts)
    end
  end

  @doc """
  Validates a visualization config against a query result.

  Checks:
  - Referenced fields exist in `result.columns` for x, y, series, and filters
  - Numeric aggregations (:sum, :avg) only apply to numeric columns

  This does not persist anything; it is safe to call before `create_`/`update_`.
  """
  @spec validate_against_result(map(), Result.t()) :: :ok | {:error, String.t()}
  def validate_against_result(%{} = cfg, %Result{} = result) do
    cfg = stringify_keys(cfg)
    cols = result.columns || []

    with :ok <- validate_x_fields(cfg, cols),
         :ok <- validate_y_fields(cfg, result),
         :ok <- validate_series_field(cfg, cols),
         :ok <- validate_filters_fields(cfg, cols) do
      :ok
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp validate_x_fields(%{"x" => %{"field" => f}}, cols) when is_binary(f),
    do: ensure_field(cols, f, "x.field")

  defp validate_x_fields(_cfg, _cols), do: :ok

  defp validate_y_fields(%{"y" => list}, result) when is_list(list),
    do: do_validate_y_fields(list, result)

  defp validate_y_fields(_cfg, _result), do: :ok

  defp do_validate_y_fields(list, %Result{} = result) do
    Enum.reduce_while(Enum.with_index(list), :ok, fn {item, idx}, _ ->
      case do_validate_single_y(item, result) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "y[#{idx}] #{msg}"}}
      end
    end)
  end

  defp do_validate_single_y(%{"field" => f} = m, result) when is_binary(f) do
    with :ok <- ensure_field(result.columns, f, "field"),
         :ok <- maybe_validate_numeric_agg(m["agg"], f, result) do
      :ok
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp do_validate_single_y(_other, _result), do: {:error, "must include field"}

  defp maybe_validate_numeric_agg(nil, _field, _result), do: :ok
  defp maybe_validate_numeric_agg("count", _field, _result), do: :ok

  defp maybe_validate_numeric_agg(agg, field, %Result{} = res) when agg in ["sum", "avg"] do
    if numeric_column?(res, field) do
      :ok
    else
      {:error, "aggregation #{agg} requires numeric field for '#{field}'"}
    end
  end

  defp maybe_validate_numeric_agg(_other, _field, _res), do: :ok

  defp validate_series_field(%{"series" => %{"field" => f}}, cols) when is_binary(f),
    do: ensure_field(cols, f, "series.field")

  defp validate_series_field(_cfg, _cols), do: :ok

  defp validate_filters_fields(%{"filters" => list}, cols) when is_list(list),
    do: do_validate_filters_fields(list, cols)

  defp validate_filters_fields(_cfg, _cols), do: :ok

  defp do_validate_filters_fields(list, cols) do
    Enum.reduce_while(Enum.with_index(list), :ok, fn {item, idx}, _ ->
      case item do
        %{"field" => f} when is_binary(f) ->
          case ensure_field(cols, f, "filters[#{idx}].field") do
            :ok -> {:cont, :ok}
            {:error, msg} -> {:halt, {:error, msg}}
          end

        _ ->
          {:halt, {:error, "filters[#{idx}].field is required"}}
      end
    end)
  end

  defp ensure_field(cols, f, label) do
    if f in (cols || []), do: :ok, else: {:error, "#{label} references unknown column '#{f}'"}
  end

  # Heuristic numeric check: look at the first non-nil value for the column
  defp numeric_column?(%Result{columns: cols, rows: rows}, field) do
    case Enum.find_index(cols || [], &(&1 == field)) do
      nil ->
        false

      idx ->
        rows
        |> Enum.map(&Enum.at(&1, idx))
        |> Enum.find(&(!is_nil(&1)))
        |> case do
          nil -> true
          v -> is_number(v)
        end
    end
  end
end
