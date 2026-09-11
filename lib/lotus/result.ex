defmodule Lotus.Result do
  @moduledoc """
  Represents the result of a query execution.

  Contains the columns, rows, and metadata about the query result.
  """

  @enforce_keys [:columns, :rows]

  defstruct columns: [],
            rows: [],
            num_rows: nil,
            duration_ms: nil,
            command: nil,
            meta: %{}

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[term()]],
          num_rows: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          command: String.t() | nil,
          meta: map()
        }

  @doc """
  Creates a new Result from columns and rows.

  ## Examples

      iex> Lotus.Result.new(["name", "age"], [["John", 25], ["Jane", 30]])
      %Lotus.Result{
        columns: ["name", "age"],
        rows: [["John", 25], ["Jane", 30]],
        num_rows: 2,
        duration_ms: nil,
        command: nil,
        meta: %{}
      }
  """
  def new(columns, rows, opts \\ []) do
    %__MODULE__{
      columns: columns || [],
      rows: rows || [],
      num_rows: Keyword.get(opts, :num_rows, length(rows || [])),
      duration_ms: Keyword.get(opts, :duration_ms),
      command: Keyword.get(opts, :command),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc """
  Returns a JSON-safe map representation of the result.

  Normalizes all row values (UUID binaries, Dates, Decimals, etc.) using
  `Lotus.Normalizer` so the output is safe for JSON encoding.
  """
  @spec to_encodable(t()) :: map()
  def to_encodable(%__MODULE__{} = result) do
    %{
      columns: result.columns,
      rows: normalize_rows(result.rows),
      num_rows: result.num_rows,
      duration_ms: result.duration_ms,
      command: result.command,
      meta: result.meta
    }
  end

  defp normalize_rows(rows) do
    Enum.map(rows, fn row ->
      Enum.map(row, &Lotus.Normalizer.normalize/1)
    end)
  end
end
