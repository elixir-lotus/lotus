if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Chart do
    @moduledoc false
    # Chart configs as Lotus Web stores and renders them (string keys,
    # `chart_type` plus the fields its type reads), built from a tool's
    # arguments and checked against the columns of the query's result.

    @types ~w(bar horizontal_bar line area combo scatter bubble histogram heatmap pie donut funnel waterfall kpi trend gauge progress sparkline)

    @value_types ~w(kpi gauge progress trend)

    # The arguments each chart type reads, as Lotus Web's chart builder does.
    @fields %{
      "kpi" => ~w(value_field label)a,
      "gauge" => ~w(value_field label min_value max_value)a,
      "progress" => ~w(value_field label goal_value)a,
      "trend" => ~w(value_field label comparison_field)a,
      "histogram" => ~w(x_field bin_count series_field)a,
      "bubble" => ~w(x_field y_field series_field size_field)a,
      "combo" => ~w(x_field y_field y2_field series_field y2_axis_title)a
    }

    @column_fields ~w(x_field y_field y2_field series_field size_field value_field comparison_field)

    @doc "The chart types."
    @spec types() :: [String.t()]
    def types, do: @types

    @doc "The chart arguments every chart-making tool declares."
    defmacro args do
      quote do
        arg :chart_type, {:enum, unquote(@types)},
          description:
            "The chart's type. kpi, gauge, progress and trend show one value_field; " <>
              "histogram bins an x_field; every other type plots y_field against x_field."

        arg :x_field, :string, description: "The column on the x axis (or the categories)"
        arg :y_field, :string, description: "The column on the y axis (or the values)"
        arg :series_field, :string, description: "A column to split into series (optional)"
        arg :y2_field, :string, description: "combo: the column on the second y axis"
        arg :size_field, :string, description: "bubble: the column for the bubble size"
        arg :value_field, :string, description: "kpi, gauge, progress, trend: the value's column"
        arg :comparison_field, :string, description: "trend: the column to compare against"
        arg :label, :string, description: "kpi, gauge, progress, trend: the value's label"
        arg :min_value, :number, description: "gauge: the scale's minimum (default 0)"
        arg :max_value, :number, description: "gauge: the scale's maximum (default 100)"
        arg :goal_value, :number, description: "progress: the goal (default 100)"

        arg :bin_count, :integer,
          min: 1,
          description: "histogram: the number of bins (default 10)"

        arg :y2_axis_title, :string, description: "combo: the second y axis's title"
      end
    end

    @doc """
    The config for `args`, checked against `columns`: `nil` when no
    `chart_type` was given (a table).
    """
    @spec config(map(), [String.t()]) :: {:ok, map() | nil} | {:error, String.t()}
    def config(args, columns) do
      case args[:chart_type] do
        nil -> {:ok, nil}
        type -> build(type, args, columns)
      end
    end

    defp build(type, args, columns) do
      config =
        @fields
        |> Map.get(type, ~w(x_field y_field series_field)a)
        |> Enum.reduce(%{"chart_type" => type}, fn key, acc ->
          case args[key] do
            nil -> acc
            "" -> acc
            value -> Map.put(acc, stored_key(key), value)
          end
        end)

      with :ok <- required(type, config), do: columns(config, columns)
    end

    # Lotus Web keeps a single value's label as `kpi_label`.
    defp stored_key(:label), do: "kpi_label"
    defp stored_key(key), do: Atom.to_string(key)

    defp required(type, config) when type in @value_types,
      do: present(config, ["value_field"], type)

    defp required("histogram", config), do: present(config, ["x_field"], "histogram")
    defp required(type, config), do: present(config, ["x_field", "y_field"], type)

    defp present(config, keys, type) do
      case Enum.reject(keys, &Map.has_key?(config, &1)) do
        [] -> :ok
        missing -> {:error, "A #{type} chart needs #{Enum.join(missing, " and ")}"}
      end
    end

    defp columns(config, columns) do
      unknown =
        for key <- @column_fields,
            column = config[key],
            column != nil,
            column not in columns,
            do: "#{key} #{inspect(column)}"

      case unknown do
        [] ->
          {:ok, config}

        unknown ->
          {:error,
           "Not a column of the query's result: #{Enum.join(unknown, ", ")}. " <>
             "Its columns are #{Enum.join(columns, ", ")}"}
      end
    end

    @doc "The columns of a saved query's result, from a run of one row."
    @spec query_columns(Lotus.Storage.Query.t(), map(), keyword()) ::
            {:ok, [String.t()]} | {:error, term()}
    def query_columns(query, vars, actor_opts) do
      opts = [read_only: true, vars: vars, window: [limit: 1, offset: 0, count: :none]]

      case Lotus.run_query(query, opts ++ actor_opts) do
        {:ok, result} -> {:ok, result.columns}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
